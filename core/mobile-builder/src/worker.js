// Claims one build at a time and does it.
//
// One worker, one queue. The claim query on the other side is already written
// for more than one, so adding a second is a compose change rather than a
// rewrite, but until somebody needs that this stays the simplest thing that
// cannot lose a build.
import { spawn } from "node:child_process";
import { readFile, rm, stat } from "node:fs/promises";
import path from "node:path";
import { assemble } from "./assemble.js";

const MOBILE = process.env.SIBERIAN_MOBILE_URL || "http://mobile:3000";
const TOKEN = process.env.SIBERIAN_BUILDER_TOKEN || "builder_dev_only";
const POLL = Number(process.env.BUILDER_POLL_INTERVAL || 10) * 1000;
const WORKSPACES = process.env.BUILDER_WORKSPACE || "/workspace";

const authorized = (extra = {}) => ({ Authorization: `Bearer ${TOKEN}`, ...extra });

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
  const log = [];
  const started = Date.now();

  const step = async (name, command, args, options = {}) => {
    const result = await run(command, args, { cwd: workspace, ...options });
    log.push(`$ ${name}\n${result.output}`);
    if (result.code !== 0) throw new BuildFailed(`${name} exited ${result.code}`, log.join("\n\n"));
    return result;
  };

  await rm(workspace, { recursive: true, force: true });
  const { sdkManaged } = await assemble(plan, workspace);
  log.push(`assembled ${plan.modules.length} module(s), ${plan.capabilities.length} capability(ies)`);

  await step("npm install", "npm", ["install", "--no-audit", "--no-fund"]);

  // `expo install` rather than a version in package.json. The SDK decides what
  // version of an expo-* package belongs with it, and installing the newest
  // instead fails much later, in Gradle, looking like a broken toolchain.
  if (sdkManaged.length > 0) {
    await step("expo install", "npx", ["expo", "install", ...sdkManaged]);
  }

  await step("expo prebuild", "npx", ["expo", "prebuild", "--platform", plan.platform, "--no-install"]);

  if (plan.platform === "ios") {
    // No compile step exists here, and pretending otherwise would produce
    // something that is not an app. The configured project is the artifact:
    // it is what a macOS runner needs and all this container can honestly make.
    await step("archive the iOS project", "zip", ["-qr", "../ios-project.zip", "ios"]);
    return { file: path.join(WORKSPACES, "ios-project.zip"), type: "application/zip", log: log.join("\n\n"), started };
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

async function report(id, outcome, body) {
  await fetch(`${MOBILE}/internal/builds/${id}`, {
    method: "PATCH",
    headers: authorized({ "Content-Type": "application/json" }),
    body: JSON.stringify({ outcome, ...body })
  });
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

async function once() {
  const claimed = await claim();
  if (!claimed) return false;

  console.log(`claimed build ${claimed.build_id} for ${claimed.plan.domain} (${claimed.plan.platform})`);

  try {
    const result = await build(claimed);
    await stat(result.file);
    await upload(claimed.build_id, result.file, result.type, Date.now() - result.started, result.log);
    console.log(`build ${claimed.build_id} succeeded`);
  } catch (error) {
    const permanent = error instanceof BuildFailed && /prebuild|bundle_identifier|npm install/i.test(error.message);
    await report(claimed.build_id, "failed", {
      error: error.message,
      permanent,
      log: error.log || String(error.stack || error)
    });
    console.log(`build ${claimed.build_id} failed: ${error.message}`);
  }

  return true;
}

async function loop() {
  console.log(`builder up, polling ${MOBILE} every ${POLL / 1000}s`);

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
