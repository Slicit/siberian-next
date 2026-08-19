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

ENV ANDROID_HOME=/opt/android \
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
                         "platform-tools" >/dev/null

# A home the worker can write to. Gradle and Metro both assume one, and running
# as root inside a container that compiles third-party code is not a thing to
# do casually.
RUN useradd -m -u 1001 builder && mkdir -p /workspace && chown builder /workspace

WORKDIR /builder
COPY core/mobile-builder/package.json /builder/package.json
COPY core/mobile-builder/src /builder/src
COPY core/mobile-builder/template /builder/template

RUN chown -R builder /builder
USER builder

CMD ["node", "src/worker.js"]
