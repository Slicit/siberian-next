// Turns a build plan into an Expo project on disk.
//
// Everything here is derived from the plan and nothing is asked of the Mobile
// service: the builder receives an answer rather than a database, because it is
// about to run third-party module code.
import { mkdir, writeFile, readFile, cp, access } from "node:fs/promises";
import path from "node:path";

// Where module source is mounted, read only. Building must never edit what it
// built from.
const CATALOGUE = process.env.BUILDER_MODULE_CATALOGUE || "/modules";

// Packages the shell always needs, whatever an operator switched on. Only the
// ones whose version is not tied to the Expo SDK are pinned here.
const BASE_DEPENDENCIES = {
  expo: "~51.0.0",
  react: "18.2.0",
  "react-native": "0.74.5",
  "@react-navigation/native": "^6.1.17",
  "@react-navigation/native-stack": "^6.9.26",
  // The bottom bar. A tab per feature is what a phone app looks like, and a
  // stack alone made every module a row in a list somebody had to go back to.
  "@react-navigation/bottom-tabs": "^6.5.20"
};

// Installed with `expo install` rather than pinned, because their version is
// decided by the SDK. Writing "*" here installs whatever is newest, which for
// an expo-* package means one built against a newer SDK: the build then fails
// deep in Gradle with a missing plugin, which reads as a toolchain problem
// rather than as a version mismatch.
const SDK_MANAGED = [
  "react-native-webview",
  "react-native-safe-area-context",
  "react-native-screens",
  // React Native for Web, so the same project can be exported as a site and
  // previewed without a device. Same components, same shell, same generated
  // module registry: a preview of something else would be worth nothing.
  "react-dom",
  "react-native-web",
  // The web entry point Metro needs to serve a React Native project as a site.
  // Absent, expo export refuses by name, which is the good kind of failure.
  "@expo/metro-runtime"
];

// A capability is a package plus, for some of them, a config plugin entry that
// carries the sentence the operating system shows. Apple rejects a build that
// asks for a permission without one, so the sentence is part of the capability
// rather than something to remember at packaging time.
const PLUGIN_FOR = {
  location: (usage) => [
    "expo-location",
    { locationAlwaysAndWhenInUsePermission: usage }
  ],
  biometric_auth: (usage) => ["expo-local-authentication", { faceIDPermission: usage }],
  app_tracking: (usage) => ["expo-tracking-transparency", { userTrackingPermission: usage }]
};

export async function assemble(plan, workspace, assets = {}) {
  await mkdir(workspace, { recursive: true });
  await cp(path.join(process.cwd(), "template"), workspace, { recursive: true });

  // Written before app.json, because app.json refers to it by path and expo
  // prebuild fails on a splash image that is not there.
  if (assets.image) await writeFile(path.join(workspace, "splash.png"), assets.image);
  if (assets.animation) await writeFile(path.join(workspace, "splash-animation.xml"), assets.animation);

  const dependencies = { ...BASE_DEPENDENCIES };
  const plugins = [];
  const sdkManaged = [...SDK_MANAGED];

  for (const capability of plan.capabilities) {
    sdkManaged.push(capability.package);

    const plugin = PLUGIN_FOR[capability.id];
    if (plugin && capability.usage) plugins.push(plugin(capability.usage));
  }

  await writeFile(
    path.join(workspace, "package.json"),
    JSON.stringify(
      {
        name: slug(plan.app.bundle_identifier),
        version: plan.app.version,
        private: true,
        main: "index.js",
        dependencies
      },
      null,
      2
    ) + "\n"
  );

  await writeFile(
    path.join(workspace, "app.json"),
    JSON.stringify(
      {
        expo: {
          name: plan.app.name,
          slug: slug(plan.app.bundle_identifier),
          version: plan.app.version,
          orientation: "portrait",
          userInterfaceStyle: "automatic",
          primaryColor: plan.app.primary_color || undefined,
          // Without this, prebuild writes a splashscreen drawable that refers
          // to a colour resource it did not write, and the build fails in
          // resource linking with "resource color/splashscreen_background not
          // found", which reads as a corrupt template rather than as missing
          // configuration.
          splash: {
            // contain rather than cover: the artwork is square and the screen
            // is not, so covering would crop the sides off a logo. Contained,
            // the whole square is always visible and the background fills the
            // rest, which is what "centred with safe zones" means in practice.
            image: assets.image ? "./splash.png" : undefined,
            backgroundColor: plan.splash?.background || plan.app.primary_color || "#ffffff",
            resizeMode: "contain"
          },
          android: {
            package: plan.app.bundle_identifier,
            versionCode: plan.app.build_number
          },
          // Metro rather than webpack: the same bundler the device build uses,
          // so the preview and the app cannot diverge over which one resolved
          // a module differently.
          // "single" and not "static": static rendering pre-renders each route
          // through expo-router, which this shell does not use, and the export
          // then fails resolving expo-router/node/render.js. A single page app
          // is what a React Navigation shell is anyway.
          web: { bundler: "metro", output: "single" },
          // Where the export will be served from. Without it every asset is
          // requested from the root of whatever host framed the preview, and
          // the panel renders a blank page with four 404s behind it.
          experiments: plan.preview?.base_url ? { baseUrl: plan.preview.base_url } : undefined,
          ios: {
            bundleIdentifier: plan.app.bundle_identifier,
            buildNumber: String(plan.app.build_number)
          },
          plugins
        }
      },
      null,
      2
    ) + "\n"
  );

  // A module that ships native code ships it in its own directory. Copied in
  // rather than imported across the filesystem, because Metro resolves from the
  // project root and a module outside it is a module Metro cannot see.
  for (const module of plan.modules) {
    if (module.kind !== "native" || !module.entry) continue;

    const from = path.join(CATALOGUE, module.name, path.dirname(module.entry));
    const to = path.join(workspace, "native", module.name);
    await mkdir(path.dirname(to), { recursive: true });
    await cp(from, to, { recursive: true });
  }

  // What the shell renders, generated rather than written: a module that ships
  // native code gets its component, one that does not gets a WebView on the
  // same UI the Base App frames, and one whose requirement an operator did not
  // approve gets the WebView too, with the reason attached so the app can say
  // why rather than showing nothing.
  await writeFile(path.join(workspace, "modules.generated.js"), renderRegistry(plan));

  await writeFile(
    path.join(workspace, "siberian.config.js"),
    `export default ${JSON.stringify(
      {
        domain: plan.domain,
        api: plan.api,
        capabilities: plan.capabilities.map((c) => c.id),
        // The chosen palette, and all of them. The shell renders from
        // whichever the query string asks for and falls back to this one,
        // which is what lets the preview try a theme on without a build.
        theme: plan.app.theme || "daylight",
        themes: plan.app.themes || {}
      },
      null,
      2
    )};\n`
  );

  return { workspace, sdkManaged };
}

function renderRegistry(plan) {
  const imports = [];
  const entries = [];

  for (const module of plan.modules) {
    if (module.kind === "none") continue;

    if (module.kind === "native" && module.entry) {
      const alias = `Mod_${identifier(module.name)}`;
      imports.push(`import * as ${alias} from "./native/${module.name}/${stripExtension(path.basename(module.entry))}";`);

      for (const screen of module.screens) {
        entries.push(
          `  {\n` +
            `    module: ${JSON.stringify(module.name)},\n` +
            `    capability: ${JSON.stringify(screen.capability)},\n` +
            `    title: ${JSON.stringify(screen.title || screen.capability)},\n` +
            `    kind: "native",\n` +
            `    component: ${alias}[${JSON.stringify(screen.component)}],\n` +
            `    apiBase: ${JSON.stringify(module.api_base)}\n` +
            `  }`
        );
      }
      continue;
    }

    entries.push(
      `  {\n` +
        `    module: ${JSON.stringify(module.name)},\n` +
        `    capability: ${JSON.stringify(module.name)},\n` +
        `    title: ${JSON.stringify(module.name)},\n` +
        `    kind: "webview",\n` +
        `    url: ${JSON.stringify(module.web_url)},\n` +
        `    reason: ${JSON.stringify(module.reason || null)},\n` +
        `    apiBase: ${JSON.stringify(module.api_base)}\n` +
        `  }`
    );
  }

  return `// Generated at build time. Do not edit: the next build overwrites it.\n${imports.join(
    "\n"
  )}\n\nexport const screens = [\n${entries.join(",\n")}\n];\n`;
}

const slug = (value) => value.replace(/[^a-zA-Z0-9]+/g, "-").toLowerCase();
const identifier = (value) => value.replace(/[^a-zA-Z0-9]+/g, "_");
const stripExtension = (value) => value.replace(/\.(js|jsx|ts|tsx)$/, "");

export async function readJson(file) {
  return JSON.parse(await readFile(file, "utf8"));
}

// The Android animated splash, applied after prebuild because it edits files
// prebuild generates.
//
// Android animates a splash through the platform splash screen API, and the
// only thing that API animates is an AnimatedVectorDrawable: not a GIF, not a
// video, not a sequence of frames. The drawable goes in res/drawable and two
// theme attributes point the splash at it.
export async function applyAndroidSplashAnimation(workspace, durationMs) {
  const source = path.join(workspace, "splash-animation.xml");

  try {
    await access(source);
  } catch {
    return false;
  }

  const drawables = path.join(workspace, "android/app/src/main/res/drawable");
  await mkdir(drawables, { recursive: true });
  await cp(source, path.join(drawables, "splashscreen_animation.xml"));

  const stylesPath = path.join(workspace, "android/app/src/main/res/values/styles.xml");
  const styles = await readFile(stylesPath, "utf8");

  // Android stops the animation at one second whatever this says, so the value
  // is clamped rather than passed through: a theme claiming three seconds is a
  // theme that lies about what the device does.
  const duration = Math.max(0, Math.min(Number(durationMs) || 1000, 1000));

  const items =
    `\n        <item name="android:windowSplashScreenAnimatedIcon">@drawable/splashscreen_animation</item>` +
    `\n        <item name="android:windowSplashScreenAnimationDuration">${duration}</item>`;

  // Anchored on the splash style prebuild writes rather than on the file's
  // shape: matching the first <style> would put these on the app theme, where
  // they do nothing and nothing says so.
  const anchor = /<style name="Theme\.App\.SplashScreen"[^>]*>/;
  if (!anchor.test(styles)) {
    throw new Error("prebuild wrote no Theme.App.SplashScreen to attach the animation to");
  }

  await writeFile(stylesPath, styles.replace(anchor, (match) => match + items));
  return true;
}
