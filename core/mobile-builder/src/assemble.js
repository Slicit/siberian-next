// Turns a build plan into an Expo project on disk.
//
// Everything here is derived from the plan and nothing is asked of the Mobile
// service: the builder receives an answer rather than a database, because it is
// about to run third-party module code.
import { mkdir, writeFile, cp, readFile } from "node:fs/promises";
import path from "node:path";

// Where module source is mounted, read only. Building must never edit what it
// built from.
const CATALOGUE = process.env.BUILDER_MODULE_CATALOGUE || "/modules";

// Packages the shell always needs, whatever an operator switched on.
const BASE_DEPENDENCIES = {
  expo: "~51.0.0",
  react: "18.2.0",
  "react-native": "0.74.5",
  "react-native-webview": "13.8.6",
  "react-native-safe-area-context": "4.10.5",
  "react-native-screens": "3.31.1",
  "@react-navigation/native": "^6.1.17",
  "@react-navigation/native-stack": "^6.9.26"
};

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

export async function assemble(plan, workspace) {
  await mkdir(workspace, { recursive: true });
  await cp(path.join(process.cwd(), "template"), workspace, { recursive: true });

  const dependencies = { ...BASE_DEPENDENCIES };
  const plugins = ["expo-router"].filter(() => false); // no router plugin yet; kept explicit

  for (const capability of plan.capabilities) {
    dependencies[capability.package] = "*";

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
          android: {
            package: plan.app.bundle_identifier,
            versionCode: plan.app.build_number
          },
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
      { domain: plan.domain, api: plan.api, capabilities: plan.capabilities.map((c) => c.id) },
      null,
      2
    )};\n`
  );

  return workspace;
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
