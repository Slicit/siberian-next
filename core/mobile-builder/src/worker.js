// Claims one build at a time and does it.
//
// One worker, one queue. The claim query on the other side is already written
// for more than one, so adding a second is a compose change rather than a
// rewrite, but until somebody needs that this stays the simplest thing that
// cannot lose a build.
import { spawn } from "node:child_process";
import { access, cp, mkdir, readFile, readdir, rm, stat } from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
import { assemble, applyAndroidSplashAnimation } from "./assemble.js";

const MOBILE = process.env.SIBERIAN_MOBILE_URL || "http://mobile:3000";
const TOKEN = process.env.SIBERIAN_BUILDER_TOKEN || "builder_dev_only";
const POLL = Number(process.env.BUILDER_POLL_INTERVAL || 10) * 1000;
const WORKSPACES = process.env.BUILDER_WORKSPACE || "/workspace";

const authorized = (extra = {}) => ({ Authorization: `Bearer ${TOKEN}`, ...extra });

// Installed dependencies, kept between builds and keyed by what was asked for.
//
// Inside the workspace volume rather than beside the npm cache, because a copy
// within one filesystem can be hardlinked and a copy across two cannot: this is
// the difference between seconds and the minutes npm install takes every time.
// The leading dot keeps it out of the sweep, which removes builds.
const MODULE_CACHE = path.join(WORKSPACES, ".modules");

async function claim() {
  const response = await fetch(`${MOBILE}/internal/builds/claim`, {
    method: "POST",
    headers: authorized()
  });

  if (response.status === 204) return null;
  if (!response.ok) throw new Error(`claim refused: ${response.status}`);

  return response.json();
}

// Every command's output is kept, whole. A build that failed and cannot say
// where is a build somebody reruns by hand to find out.
function run(command, args, options) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { ...options, shell: false });
    let output = "";

    child.stdout.on("data", (chunk) => (output += chunk));
    child.stderr.on("data", (chunk) => (output += chunk));
    child.on("error", (error) => resolve({ code: 127, output: `${output}\n${error.message}` }));
    child.on("close", (code) => resolve({ code, output }));
  });
}

async function build({ build_id: id, plan }) {
  const workspace = path.join(WORKSPACES, String(id));
  await mkdir(MODULE_CACHE, { recursive: true });
  const log = [];
  const started = Date.now();

  const step = async (name, command, args, options = {}) => {
    const result = await run(command, args, { cwd: workspace, ...options });
    log.push(`$ ${name}\n${result.output}`);
    if (result.code !== 0) throw new BuildFailed(`${name} exited ${result.code}`, log.join("\n\n"));
    return result;
  };

  await rm(workspace, { recursive: true, force: true });

  // Fetched before assembling, because app.json refers to the splash image by
  // path and prebuild fails on one that is not there yet.
  const assets = {
    image: plan.splash?.image ? await asset(id, "image") : null,
    animation: plan.splash?.animation ? await asset(id, "animation") : null
  };

  const { sdkManaged } = await assemble(plan, workspace, assets);
  log.push(`assembled ${plan.modules.length} module(s), ${plan.capabilities.length} capability(ies)`);

  // Dependencies, from cache when the same set has been installed before.
  //
  // Every build installs about a thousand packages, and deleting the workspace
  // afterwards means doing it again from nothing: that was most of the ten
  // minutes a preview took. The set only changes when a capability is switched
  // on or a module starts shipping native code, so it is keyed by exactly that
  // and copied in with hardlinks, which costs a directory walk rather than a
  // download.
  const key = createHash("sha1")
    .update(JSON.stringify({ deps: plan.capabilities.map((c) => c.package).sort(), sdk: sdkManaged.slice().sort() }))
    .digest("hex")
    .slice(0, 12);

  const cached = path.join(MODULE_CACHE, key);
  const warm = await exists(cached);

  if (warm) {
    await step("restore dependencies", "cp", ["-al", cached, path.join(workspace, "node_modules")], { cwd: WORKSPACES });
    log.push(`restored node_modules from cache ${key}`);
  } else {
    await step("npm install", "npm", ["install", "--no-audit", "--no-fund", "--prefer-offline"]);

    // `expo install` rather than a version in package.json. The SDK decides
    // what version of an expo-* package belongs with it, and installing the
    // newest instead fails much later, in Gradle, looking like a broken
    // toolchain.
    if (sdkManaged.length > 0) {
      await step("expo install", "npx", ["expo", "install", ...sdkManaged]);
    }

    // Cached only after both installs, so a half-installed tree is never what
    // the next build starts from.
    await cp(path.join(workspace, "node_modules"), cached, { recursive: true }).catch((error) =>
      log.push(`could not cache node_modules: ${error.message}`)
    );
  }


  // The preview. Not a device build at all: the same project rendered through
  // React Native for Web and exported as a static site, so somebody can look at
  // the app while they are still deciding what it should contain.
  //
  // Before prebuild, and instead of it: there are no native projects to
  // generate for the web, and asking prebuild for that platform is asking for
  // something it does not have. No compile either, which is the only reason
  // this is quick enough to be worth looking at.
  if (plan.platform === "web") {
    await step("expo export", "npx", ["expo", "export", "--platform", "web", "--output-dir", "dist"]);

    return { directory: path.join(workspace, "dist"), log: log.join("\n\n"), started };
  }

  await step("expo prebuild", "npx", ["expo", "prebuild", "--platform", plan.platform, "--no-install"]);

  if (plan.platform === "ios") {
    // No compile step exists here, and pretending otherwise would produce
    // something that is not an app. The configured project is the artifact: it
    // is what a macOS runner needs and all this container can honestly make.
    //
    // The JavaScript side goes in with it. The generated Podfile resolves React
    // Native pods through node_modules, so an ios/ directory on its own is not
    // something `pod install` can complete: whoever opens this has to run npm
    // install first, and cannot without the manifest saying what to install.
    const archive = "ios-project.zip";
    const contents = ["ios", "package.json", "app.json", "modules.generated.js", "siberian.config.js"];
    if (plan.modules.some((module) => module.kind === "native")) contents.push("native");

    // Inside the build's own workspace rather than beside it. A fixed path
    // shared by every build is a file the second worker would overwrite while
    // the first was still reading it, and the claim query is already written
    // for a second worker.
    await step("archive the iOS project", "zip", ["-qr", archive, ...contents]);

    return {
      file: path.join(workspace, archive),
      type: "application/zip",
      log: log.join("\n\n"),
      started
    };
  }

  if (assets.animation) {
    const applied = await applyAndroidSplashAnimation(workspace, plan.splash?.animation_duration_ms);
    log.push(applied ? "applied the animated splash" : "no animated splash to apply");
  }

  await step("gradle assembleRelease", "./gradlew", ["assembleRelease", "--no-daemon"], {
    cwd: path.join(workspace, "android")
  });

  return {
    file: path.join(workspace, "android/app/build/outputs/apk/release/app-release.apk"),
    type: "application/vnd.android.package-archive",
    log: log.join("\n\n"),
    started
  };
}

class BuildFailed extends Error {
  constructor(message, log) {
    super(message);
    this.log = log;
  }
}

// The bytes of an asset the build needs. The builder holds no Storage
// credential: it asks by kind and is handed the file, or 204 when there is
// none, which is the ordinary case rather than an error.
async function asset(id, kind) {
  const response = await fetch(`${MOBILE}/internal/builds/${id}/asset/${kind}`, { headers: authorized() });

  if (response.status === 204) return null;
  if (!response.ok) throw new Error(`${kind} asset refused: ${response.status}`);

  return Buffer.from(await response.arrayBuffer());
}

async function report(id, outcome, body) {
  await fetch(`${MOBILE}/internal/builds/${id}`, {
    method: "PATCH",
    headers: authorized({ "Content-Type": "application/json" }),
    body: JSON.stringify({ outcome, ...body })
  });
}

// The preview, file by file.
//
// A static export is a directory, and the builder holds no Storage credential,
// so each file goes back through the Mobile service the way the artifact does.
// Many small files rather than one archive, because unzipping on the other side
// would mean a zip library in a service with no other use for one.
async function uploadDirectory(id, directory) {
  const walk = async (here, prefix = "") => {
    const entries = await readdir(here, { withFileTypes: true });
    let count = 0;

    for (const entry of entries) {
      const full = path.join(here, entry.name);
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;

      if (entry.isDirectory()) {
        count += await walk(full, relative);
        continue;
      }

      const response = await fetch(
        `${MOBILE}/internal/builds/${id}/preview?path=${encodeURIComponent(relative)}`,
        { method: "POST", headers: authorized({ "Content-Type": contentType(entry.name) }), body: await readFile(full) }
      );

      if (!response.ok) throw new Error(`the preview file ${relative} was not accepted: ${response.status}`);
      count += 1;
    }

    return count;
  };

  return walk(directory);
}

// Guessed from the name, because in a static site a stylesheet served as
// octet-stream is a page with no styles and no error anywhere.
function contentType(name) {
  const kinds = {
    ".html": "text/html", ".js": "text/javascript", ".css": "text/css",
    ".json": "application/json", ".map": "application/json", ".svg": "image/svg+xml",
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
    ".webp": "image/webp", ".ttf": "font/ttf", ".woff": "font/woff", ".woff2": "font/woff2"
  };

  const at = name.lastIndexOf(".");
  return (at >= 0 && kinds[name.slice(at).toLowerCase()]) || "application/octet-stream";
}

async function upload(id, file, type, durationMs, log) {
  const body = await readFile(file);

  const response = await fetch(`${MOBILE}/internal/builds/${id}/artifact?duration_ms=${durationMs}`, {
    method: "POST",
    headers: authorized({ "Content-Type": type }),
    body
  });

  // A refusal here is Storage saying the domain is full, and the Mobile service
  // has already recorded it. Reporting again would overwrite that with a worse
  // explanation.
  if (!response.ok && response.status !== 507) {
    throw new Error(`the artifact was not accepted: ${response.status}`);
  }
}

// A finished build's workspace is roughly 800 MB of node_modules and Gradle
// output, and it explains nothing once the build has reported: the log is on
// the row and the artifact is in Storage. Left behind, sixteen of them filled
// a 47 GB disk and Postgres stopped being able to write, which does not look
// like a build problem from anywhere else.
async function discard(id) {
  try {
    await rm(path.join(WORKSPACES, String(id)), { recursive: true, force: true });
  } catch (error) {
    // Worth saying and not worth failing a finished build over.
    console.error(`could not remove the workspace for build ${id}: ${error.message}`);
  }
}

// Anything here at startup belonged to a build this process was running, and
// this process has just started. Removing the children rather than the
// directory, because the directory is a mount point.
async function exists(target) {
  try {
    await access(target);
    return true;
  } catch {
    return false;
  }
}

async function sweep() {
  let left;

  try {
    left = await readdir(WORKSPACES);
  } catch {
    return;
  }

  // Anything beginning with a dot is not a build. The dependency cache lives
  // here so it shares a filesystem with the workspaces it is hardlinked into.
  const builds = left.filter((entry) => !entry.startsWith("."));

  for (const entry of builds) {
    await rm(path.join(WORKSPACES, entry), { recursive: true, force: true }).catch(() => {});
  }

  if (builds.length > 0) console.log(`swept ${builds.length} workspace(s) left by a previous run`);
}

async function once() {
  const claimed = await claim();
  if (!claimed) return false;

  console.log(`claimed build ${claimed.build_id} for ${claimed.plan.domain} (${claimed.plan.platform})`);

  try {
    const result = await build(claimed);

    if (result.directory) {
      const files = await uploadDirectory(claimed.build_id, result.directory);
      await report(claimed.build_id, "succeeded", {
        artifact_path: "preview",
        duration_ms: Date.now() - result.started,
        log: result.log
      });
      console.log(`build ${claimed.build_id} previewed, ${files} file(s)`);
    } else {
      await stat(result.file);
      await upload(claimed.build_id, result.file, result.type, Date.now() - result.started, result.log);
      console.log(`build ${claimed.build_id} succeeded`);
    }
  } catch (error) {
    const permanent = error instanceof BuildFailed && /prebuild|bundle_identifier|npm install/i.test(error.message);
    await report(claimed.build_id, "failed", {
      error: error.message,
      permanent,
      log: error.log || String(error.stack || error)
    });
    console.log(`build ${claimed.build_id} failed: ${error.message}`);
  } finally {
    // Both ways. A failed build is explained by its log, which has already been
    // reported by the time this runs.
    await discard(claimed.build_id);
  }

  return true;
}

async function loop() {
  console.log(`builder up, polling ${MOBILE} every ${POLL / 1000}s`);
  await sweep();

  for (;;) {
    try {
      // Straight back round when there was work: a queue that empties in bursts
      // should not wait out the poll interval between two builds.
      const worked = await once();
      if (!worked) await new Promise((resolve) => setTimeout(resolve, POLL));
    } catch (error) {
      console.error(`builder loop: ${error.message}`);
      await new Promise((resolve) => setTimeout(resolve, POLL));
    }
  }
}

loop();
