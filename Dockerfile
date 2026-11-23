# Sonatype Nexus Repository on openSUSE Tumbleweed (scratch + JRE rootfs)

ARG BASE=docker.io/opensuse/tumbleweed:latest@sha256:873ddd8d2a548bbd38c9d8485bd710ab6d17d013cacb38a252005f634b3ab187
ARG NEXUS_VERSION="3.98.3-01"
ARG NEXUS_DB_MIGRATOR_VERSION="3.98.3-01"
ARG JAVA_VERSION="21"
ARG USER_ID="1000"
ARG IMAGE_TITLE="Sonatype Nexus Repository on openSUSE Tumbleweed"
ARG IMAGE_DESCRIPTION="Sonatype Nexus Repository running on a minimal openSUSE Tumbleweed JRE root filesystem."
ARG IMAGE_AUTHORS="Paul Christophel <pmartin@gatech.edu>"
ARG IMAGE_OWNER="Paul Christophel <pmartin@gatech.edu>"
ARG IMAGE_VENDOR="Paul Christophel"
ARG IMAGE_SOURCE="https://github.gatech.edu/epi/docker-nexus"
ARG IMAGE_REPOSITORY="unknown"
ARG IMAGE_URL="https://github.gatech.edu/epi/docker-nexus"
ARG IMAGE_DOCUMENTATION="https://github.gatech.edu/epi/docker-nexus#readme"
ARG IMAGE_REVISION="unknown"
ARG IMAGE_CREATED="1970-01-01T00:00:00Z"
ARG IMAGE_LICENSES="Apache-2.0"

################################################################################
# base: download + verify + lay out Nexus under /opt/sonatype and /nexus-data
################################################################################
FROM $BASE AS base
ARG NEXUS_VERSION
ARG NEXUS_DB_MIGRATOR_VERSION
ARG USER_ID

# nexus latest binary release link
# https://help.sonatype.com/repomanager3/download/download-archives---repository-manager-3
ARG NEXUS_URL="https://download.sonatype.com/nexus"
ARG NEXUS_TARBALL_URL="${NEXUS_URL}/3/nexus-${NEXUS_VERSION}-linux-x86_64.tar.gz"
ARG NEXUS_DB_MIGRATOR_URL="${NEXUS_URL}/nxrm3-migrator/nexus-db-migrator-${NEXUS_DB_MIGRATOR_VERSION}.jar"
#ARG GPG_KEY=0374CF2E8DD1BDFD
#ARG GPG_KEY=27C7B9756A9C691EE87696FB5C9BD9F4EAAD7054
ARG GPG_KEY=597C0366188C68248783F5CCDC2B2F5E049000B3

ARG SONATYPE_DIR=/opt/sonatype
ARG NEXUS_HOME=/opt/sonatype/nexus
ARG NEXUS_DATA=/nexus-data
ARG SONATYPE_WORK=/opt/sonatype/sonatype-work

USER root
RUN zypper --non-interactive --gpg-auto-import-keys install --no-recommends \
      coreutils curl dirmngr gpg2 gzip tar \
 && cd /tmp \
 && echo "===> Installing Nexus ${NEXUS_VERSION}..." \
 && curl -fsSL --output nexus.tar.gz "${NEXUS_TARBALL_URL}" \
 && echo "$(curl -fsSL "${NEXUS_TARBALL_URL}.sha512")  nexus.tar.gz" | sha512sum -c - \
 && tar -xzf nexus.tar.gz --exclude='nexus-*/jdk' \
 && mkdir -p "${SONATYPE_DIR}" \
 && mv "nexus-${NEXUS_VERSION}" "${NEXUS_HOME}" \
 && cd "${NEXUS_HOME}" \
 && echo "===> Downloading ${GPG_KEY}" \
 && gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "${GPG_KEY}" \
 && echo "===> Downloading ${NEXUS_DB_MIGRATOR_URL}" \
 && curl -fsSL --output nexus-db-migrator.jar "${NEXUS_DB_MIGRATOR_URL}" \
 && curl -fsSL --output nexus-db-migrator.jar.asc "${NEXUS_DB_MIGRATOR_URL}.asc" \
 && gpg --batch --verify nexus-db-migrator.jar.asc nexus-db-migrator.jar \
 && rm nexus-db-migrator.jar.asc \
 && sed -e '/^nexus-context/ s:$:${NEXUS_CONTEXT}:' \
        -i "${NEXUS_HOME}/etc/nexus-default.properties" \
 # keep 30 days of logs rather than the 90 day default
 && sed -i -e 's|<maxHistory>90</maxHistory>|<maxHistory>30</maxHistory>|g' \
        "${NEXUS_HOME}"/etc/logback/logback*.xml \
 && ln -svf "sonatype-nexus-repository-${NEXUS_VERSION}.jar" \
        "${NEXUS_HOME}/bin/sonatype-nexus-repository.jar" \
 && mkdir -p "${NEXUS_DATA}/etc" "${NEXUS_DATA}/log" "${NEXUS_DATA}/tmp" \
             "${NEXUS_DATA}/javaprefs" "${SONATYPE_WORK}" \
 && ln -s "${NEXUS_DATA}" "${SONATYPE_WORK}/nexus3" \
 && chown -R "${USER_ID}:${USER_ID}" "${NEXUS_DATA}" "${SONATYPE_DIR}" \
 && ls -las "${NEXUS_HOME}" "${NEXUS_HOME}/bin" \
 && rm -rf /tmp/* /root/.gnupg


################################################################################
# runtime-builder: minimal Tumbleweed root with only the JRE + openSUSE-release.
# /etc/os-release and the rpm database are kept so Harbor/Trivy can identify
# the OS and enumerate installed packages.
################################################################################
FROM $BASE AS runtime-builder
ARG JAVA_VERSION
ARG USER_ID

USER root
RUN mkdir -p /etc/zypp \
 && printf '[main]\nrpm.install.excludedocs = yes\nsolver.onlyRequires = true\n' > /etc/zypp/zypp.conf \
 && mkdir -p /mnt/rootfs \
 && zypper --installroot /mnt/rootfs \
      --non-interactive \
      --gpg-auto-import-keys \
      install --no-recommends \
      openSUSE-release \
      "java-${JAVA_VERSION}-openjdk-headless" \
 && zypper --installroot /mnt/rootfs --non-interactive update -y \
 && zypper --installroot /mnt/rootfs --non-interactive clean --all \
 # Stable JAVA_HOME (/opt/java) that doesn't depend on the alternatives system
 && set -- /mnt/rootfs/usr/lib64/jvm/java-${JAVA_VERSION}-openjdk*/bin/java \
 && java_bin="$1" \
 && test -f "${java_bin}" -a -x "${java_bin}" \
 && mkdir -p /mnt/rootfs/opt \
 && ln -sfn "$(dirname "$(dirname "${java_bin#/mnt/rootfs}")")" /mnt/rootfs/opt/java \
 # Strip packages only needed for install-time scriptlets (shell, coreutils,
 # cert tooling, alternatives). rpm -e removes their files AND their rpm db
 # entries, so Harbor/Trivy sees exactly what is in the image.
 && strip_packages="" \
 && for p in \
      bash bash-sh coreutils findutils file file-magic libmagic1 \
      p11-kit-tools javapackages-tools alts libalternatives1 \
      compat-usrmerge-tools libreadline8 libncurses6 terminfo-base; do \
      if rpm --root /mnt/rootfs -q "$p" >/dev/null 2>&1; then strip_packages="${strip_packages} $p"; fi; \
    done \
 && echo "===> Removing from rootfs:${strip_packages}" \
 && rpm --root /mnt/rootfs -e --nodeps --noscripts --notriggers ${strip_packages} \
 # Drop the now-dangling alternatives links (java, keytool, rmiregistry -> alts).
 # They are not owned by any package, so the rpm db is unaffected.
 && for f in /mnt/rootfs/usr/bin/* /mnt/rootfs/usr/sbin/*; do \
      if [ -L "$f" ] && [ "$(readlink "$f")" = "/usr/bin/alts" ]; then \
        echo "===> Removing dangling link ${f#/mnt/rootfs}"; rm -f "$f"; \
      fi; \
    done \
 && rm -rf /mnt/rootfs/var/cache/zypp /mnt/rootfs/var/log/* /mnt/rootfs/tmp/* \
 && echo "nexus:x:${USER_ID}:${USER_ID}:Nexus:/nexus-data:/usr/sbin/nologin" >> /mnt/rootfs/etc/passwd \
 && echo "nexus:x:${USER_ID}:" >> /mnt/rootfs/etc/group \
 # Smoke test (runs here because the final image has no shell)
 && . /mnt/rootfs/etc/os-release \
 && test "${ID}" = "opensuse-tumbleweed" \
 && rpm --root /mnt/rootfs -q openSUSE-release "java-${JAVA_VERSION}-openjdk-headless" \
 && ! rpm --root /mnt/rootfs -q bash >/dev/null 2>&1 \
 && test ! -e /mnt/rootfs/usr/bin/sh -a ! -e /mnt/rootfs/usr/bin/bash \
 && test -s /mnt/rootfs/var/lib/ca-certificates/java-cacerts \
 # The chroot has no /proc, so ld.so can't expand java's $ORIGIN/../lib RUNPATH
 # to find libjli.so. Point it there explicitly; at runtime /proc is mounted.
 && LD_LIBRARY_PATH=/opt/java/lib chroot /mnt/rootfs /opt/java/bin/java \
      -XX:+UnlockDiagnosticVMOptions -XX:-UseBASE64Intrinsics \
      --add-reads=java.xml=java.logging \
      --add-opens=java.rmi/sun.rmi.transport.tcp=ALL-UNNAMED \
      --add-exports=jdk.naming.rmi/com.sun.jndi.url.rmi=ALL-UNNAMED \
      -version \
 && echo "===> Remaining packages:" \
 && rpm --root /mnt/rootfs -qa --qf '%{NAME}\n' | sort \
 && echo "===> Remaining executables:" \
 && { ls -l /mnt/rootfs/usr/bin /mnt/rootfs/usr/sbin 2>/dev/null || true; }


################################################################################
# slim (default): scratch + Tumbleweed JRE rootfs + Nexus
################################################################################
FROM scratch AS slim
ARG BASE
ARG NEXUS_VERSION
ARG JAVA_VERSION
ARG USER_ID
ARG IMAGE_TITLE
ARG IMAGE_DESCRIPTION
ARG IMAGE_AUTHORS
ARG IMAGE_OWNER
ARG IMAGE_VENDOR
ARG IMAGE_SOURCE
ARG IMAGE_REPOSITORY
ARG IMAGE_URL
ARG IMAGE_DOCUMENTATION
ARG IMAGE_REVISION
ARG IMAGE_CREATED
ARG IMAGE_LICENSES

LABEL maintainer="${IMAGE_AUTHORS}"
LABEL org.opencontainers.image.created="${IMAGE_CREATED}"
LABEL org.opencontainers.image.base.name="${BASE}"
LABEL org.opencontainers.image.authors="${IMAGE_AUTHORS}"
LABEL org.opencontainers.image.title="${IMAGE_TITLE}"
LABEL org.opencontainers.image.description="${IMAGE_DESCRIPTION}"
LABEL org.opencontainers.image.vendor="${IMAGE_VENDOR}"
LABEL org.opencontainers.image.source="${IMAGE_SOURCE}"
LABEL org.opencontainers.image.url="${IMAGE_URL}"
LABEL org.opencontainers.image.documentation="${IMAGE_DOCUMENTATION}"
LABEL org.opencontainers.image.version="${NEXUS_VERSION}"
LABEL org.opencontainers.image.revision="${IMAGE_REVISION}"
LABEL org.opencontainers.image.licenses="${IMAGE_LICENSES}"
LABEL org.opencontainers.image.ref.name="${IMAGE_REPOSITORY}"
LABEL org.opencontainers.image.component.nexus.version="${NEXUS_VERSION}"
LABEL org.opencontainers.image.component.java.version="${JAVA_VERSION}"
LABEL edu.gatech.image.owner="${IMAGE_OWNER}"
LABEL edu.gatech.image.repository="${IMAGE_REPOSITORY}"

COPY --from=runtime-builder /mnt/rootfs/ /
COPY --from=base /opt /opt
# --chown so /nexus-data itself (not just its contents) is owned by the nexus user
COPY --from=base --chown=${USER_ID}:${USER_ID} /nexus-data /nexus-data

ENV SONATYPE_DIR="/opt/sonatype" \
    NEXUS_HOME="/opt/sonatype/nexus" \
    NEXUS_DATA="/nexus-data" \
    NEXUS_CONTEXT="" \
    SONATYPE_WORK="/opt/sonatype/sonatype-work" \
    USER_ID="${USER_ID}"

# Tunables. Picked up automatically by the `java` launcher, so they can be
# overridden with `-e JDK_JAVA_OPTIONS=...` without repeating the required
# argument list in ENTRYPOINT.
# NOTE: heap (65% of the container limit) + MaxDirectMemorySize must fit inside
# the container memory limit, so give the container at least ~8G or lower these.
ENV JDK_JAVA_OPTIONS="-XX:+UseG1GC -XX:MaxRAMPercentage=65 -XX:MaxDirectMemorySize=4G -XX:+ExitOnOutOfMemoryError"

ENV JAVA_HOME="/opt/java"

# No shell in this image: smoke tests run in runtime-builder.
USER ${USER_ID}:${USER_ID}
VOLUME /nexus-data
EXPOSE 8081
WORKDIR /opt/sonatype/nexus

# Mirrors bin/nexus.vmoptions from the Nexus tarball, with absolute paths
# (so it doesn't depend on WORKDIR) and container-friendly logging (stdout
# instead of jvm.log).
ENTRYPOINT [ \
  "/opt/java/bin/java", \
  "-XX:+UnlockDiagnosticVMOptions", \
  "-XX:-UseBASE64Intrinsics", \
  "-XX:-OmitStackTraceInFastThrow", \
  "-Dkaraf.home=/opt/sonatype/nexus", \
  "-Dkaraf.base=/opt/sonatype/nexus", \
  "-Dkaraf.data=/nexus-data", \
  "-Dkaraf.log=/nexus-data/log", \
  "-Djava.io.tmpdir=/nexus-data/tmp", \
  "-Djava.util.prefs.userRoot=/nexus-data/javaprefs", \
  "-Djava.util.logging.config.file=/opt/sonatype/nexus/etc/spring/java.util.logging.properties", \
  "-Djdk.tls.ephemeralDHKeySize=2048", \
  "-Dfile.encoding=UTF-8", \
  "--add-reads=java.xml=java.logging", \
  "--add-opens=java.base/java.security=ALL-UNNAMED", \
  "--add-opens=java.base/java.net=ALL-UNNAMED", \
  "--add-opens=java.base/java.lang=ALL-UNNAMED", \
  "--add-opens=java.base/java.util=ALL-UNNAMED", \
  "--add-opens=java.naming/javax.naming.spi=ALL-UNNAMED", \
  "--add-opens=java.rmi/sun.rmi.transport.tcp=ALL-UNNAMED", \
  "--add-exports=java.base/sun.net.www.protocol.http=ALL-UNNAMED", \
  "--add-exports=java.base/sun.net.www.protocol.https=ALL-UNNAMED", \
  "--add-exports=java.base/sun.net.www.protocol.jar=ALL-UNNAMED", \
  "--add-exports=jdk.xml.dom/org.w3c.dom.html=ALL-UNNAMED", \
  "--add-exports=jdk.naming.rmi/com.sun.jndi.url.rmi=ALL-UNNAMED", \
  "--add-exports=java.security.sasl/com.sun.security.sasl=ALL-UNNAMED", \
  "--add-exports=java.base/sun.security.x509=ALL-UNNAMED", \
  "--add-exports=java.base/sun.security.rsa=ALL-UNNAMED", \
  "--add-exports=java.base/sun.security.pkcs=ALL-UNNAMED", \
  "-jar", \
  "/opt/sonatype/nexus/bin/sonatype-nexus-repository.jar"]
CMD []
