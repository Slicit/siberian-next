// Claims one build at a time and does it.
//
// One worker per lane. The claim query on the other side takes a lock with
// SKIP LOCKED, so two workers running it at the same moment step over each
// other rather than queueing, and BUILDER_LANES decides which queue each one
// is looking at. A worker told nothing takes anything, which is what this was
// before there were lanes.
import { spawn } from "node:child_process";
import { access, cp, mkdir, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { assemble, applyAndroidSplashAnimation } from "./assemble.js";

const MOBILE = process.env.SIBERIAN_MOBILE_URL || "http://mobile:3000";
const TOKEN = process.env.SIBERIAN_BUILDER_TOKEN || "builder_dev_only";
const POLL = Number(process.env.BUILDER_POLL_INTERVAL || 10) * 1000;
const WORKSPACES = process.env.BUILDER_WORKSPACE || "/workspace";

// Which queues this worker takes from. Empty means all of them, which is what
// a single builder was and still is.
//
// The point of splitting is that a web export takes about a minute and a
// Gradle build takes twenty, so one queue made the minute wait for the twenty.
// Two workers, not two priorities: with one worker a priority queue still
// leaves the preview waiting for the Android build to let go of it.
const LANES = (process.env.BUILDER_LANES || "").split(",").map((lane) => lane.trim()).filter(Boolean);

const authorized = (extra = {}) => ({ Authorization: `Bearer ${TOKEN}`, ...extra });

// Installed dependencies, kept between builds and keyed by what was asked for.
//
// Inside the workspace volume rather than beside the npm cache, because a copy
// within one filesystem can be hardlinked and a copy across two cannot: this is
// the difference between seconds and the minutes npm install takes every time.
// The leading dot keeps it out of the sweep, which removes builds.
const MODULE_CACHE = path.join(WORKSPACES, ".modules");

async function claim() {
  const url = new URL(`${MOBILE}/internal/builds/claim`);
  if (LANES.length > 0) url.searchParams.set("lanes", LANES.join(","));

  const response = await fetch(url, {
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
    //
    // verbatimSymlinks matters more than it looks. node_modules/.bin is a
    // directory of relative symlinks, and without this Node resolves each one
    // and writes it as an absolute path into the workspace that happened to
    // create the cache. That workspace is deleted when its build finishes, so
    // every later build restores a .bin full of links to nothing and dies with
    // "expo: not found", which reads as a broken image rather than a cache
    // that poisoned itself.
    await cp(path.join(workspace, "node_modules"), cached, { recursive: true, verbatimSymlinks: true }).catch((error) =>
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
    log.push(await relativiseExport(path.join(workspace, "dist")));

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

// Expo writes its asset references root-absolute: `/_expo/static/js/...`. That
// is right for a site served from the root of a host, and wrong for this one.
// The preview is served under `/mobile/:id/preview/`, so the browser asked the
// Backoffice root for the bundle, got a 404, and rendered a blank page: the
// export was fine and unreachable, which is the worst of the two failures
// because everything upstream of it reports success.
//
// Rewritten here rather than in the page that frames it, so the export is a
// directory that works wherever it is put down.
async function relativiseExport(directory) {
  const pages = (await readdir(directory, { withFileTypes: true }))
    .filter((entry) => entry.isFile() && entry.name.endsWith(".html"))
    .map((entry) => path.join(directory, entry.name));

  let changed = 0;
  const referenced = new Set();

  for (const page of pages) {
    const before = await readFile(page, "utf8");
    const after = before.replace(/(src|href)="\/(_expo\/|assets\/|favicon)/g, '$1="$2');

    for (const [, , reference] of after.matchAll(/(src|href)="([^"?#:]+)["?#]/g)) {
      if (reference.startsWith("/") || reference.length === 0) continue;
      referenced.add(reference);
    }

    if (after !== before) {
      await writeFile(page, after);
      changed += 1;
    }
  }

  // Every path the page names has to be a file in the directory that is about
  // to be uploaded. Getting this wrong does not fail anything: the export
  // succeeds, the upload succeeds, the build reports success, and the preview
  // is a blank frame whose only symptom is in a browser console nobody is
  // watching. So it fails here instead, where there is a log.
  const missing = [];

  for (const reference of referenced) {
    await access(path.join(directory, reference)).catch(() => missing.push(reference));
  }

  if (missing.length > 0) {
    throw new BuildFailed(`the export names ${missing.length} file(s) it does not contain: ${missing.join(", ")}`);
  }

  return `made asset paths relative in ${changed} page(s) of ${pages.length}, ${referenced.size} reference(s) checked`;
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

// The builder's own source, hashed.
//
// `core/mobile-builder` is bind mounted, which makes an edit on the box look
// live: the file inside the container changes immediately. Node does not
// reread a module after it has loaded it, so the running worker kept building
// from the code it started with. A build then succeeds, reports success, and
// silently produces the previous version of the app, which is the failure that
// takes longest to notice because nothing anywhere says anything is wrong.
//
// So the worker notices instead. Between builds, never during one, it compares
// its source to what is on disk and exits when they differ. Compose restarts
// it, and the next build runs the code that is checked out.
async function fingerprint() {
  const hash = createHash("sha256");
  const here = path.dirname(fileURLToPath(import.meta.url));

  for (const name of (await readdir(here)).sort()) {
    if (!name.endsWith(".js")) continue;
    hash.update(name);
    hash.update(await readFile(path.join(here, name)));
  }

  return hash.digest("hex").slice(0, 12);
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
  const source = await fingerprint();
  console.log(`builder up (source ${source}), polling ${MOBILE} every ${POLL / 1000}s`);
  await sweep();

  for (;;) {
    try {
      // Straight back round when there was work: a queue that empties in bursts
      // should not wait out the poll interval between two builds.
      const worked = await once();

      const now = await fingerprint().catch(() => source);
      if (now !== source) {
        console.log(`builder source changed (${source} to ${now}), restarting`);
        return;
      }

      if (!worked) await new Promise((resolve) => setTimeout(resolve, POLL));
    } catch (error) {
      console.error(`builder loop: ${error.message}`);
      await new Promise((resolve) => setTimeout(resolve, POLL));
    }
  }
}

loop();
