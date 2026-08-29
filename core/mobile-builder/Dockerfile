# The build container. Node, because the toolchain it drives is Expo's, and a
# JDK plus the Android SDK, because an APK is compiled here rather than
# somewhere else.
#
# iOS is absent on purpose. Apple's toolchain runs on macOS only, so this
# container produces the configured iOS project as an archive and stops. That
# is a fact about Apple, not a decision that can be revisited here.
FROM node:20-bookworm-slim

ARG ANDROID_SDK_VERSION=11076708
ARG ANDROID_PLATFORM=34
ARG ANDROID_BUILD_TOOLS=34.0.0
# Expo modules compile native code, so the NDK is not optional. Gradle will
# otherwise try to install it itself, at build time, into a directory it cannot
# write, and the failure reads as an SDK permissions problem.
ARG ANDROID_NDK=26.1.10909125

ENV ANDROID_HOME=/opt/android \
    ANDROID_NDK_HOME=/opt/android/ndk/26.1.10909125 \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    GRADLE_USER_HOME=/home/builder/.gradle

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openjdk-17-jdk-headless git curl unzip zip ca-certificates python3 \
 && rm -rf /var/lib/apt/lists/*

# The command line tools expect to live at cmdline-tools/latest, and put
# themselves one directory higher when unzipped. Getting this wrong produces
# "Could not determine SDK root", which reads as a missing SDK.
RUN mkdir -p "$ANDROID_HOME/cmdline-tools" \
 && curl -fsSL -o /tmp/tools.zip \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip" \
 && unzip -q /tmp/tools.zip -d "$ANDROID_HOME/cmdline-tools" \
 && mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" \
 && rm /tmp/tools.zip

ENV PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

RUN yes | sdkmanager --licenses >/dev/null \
 && sdkmanager --install "platforms;android-${ANDROID_PLATFORM}" \
                         "build-tools;${ANDROID_BUILD_TOOLS}" \
                         "platform-tools" \
                         "ndk;${ANDROID_NDK}" \
                         "cmake;3.22.1" >/dev/null

# A home the worker can write to, and an SDK it can write into: Gradle installs
# into ANDROID_HOME while configuring, and the failure when it cannot reads as
# "the SDK directory is not writable", which sounds like a missing mount rather
# than a user. Running as root would also fix it and is exactly the wrong answer
# in a container that compiles code somebody else wrote.
RUN useradd -m -u 1001 builder \
 && mkdir -p /workspace \
 && chown builder /workspace \
 && chown -R builder "$ANDROID_HOME"

WORKDIR /builder
COPY core/mobile-builder/package.json /builder/package.json
COPY core/mobile-builder/src /builder/src
COPY core/mobile-builder/template /builder/template

RUN chown -R builder /builder
USER builder


# A JSX parser, for bin/check-native.
#
# Last, so changing it rebuilds one small layer rather than the Android SDK
# above it. In this image because this is the image that already knows what a
# native screen is, and because a check that needs the network to run is a check
# that fails when the network does.
USER root
RUN npm install --prefix /opt/checktools --no-audit --no-fund @babel/parser@7.24.7 \
 && chown -R builder /opt/checktools
USER builder

CMD ["node", "src/worker.js"]
