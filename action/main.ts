import * as core from "@actions/core";
import * as exec from "@actions/exec";
import * as tc from "@actions/tool-cache";
import { createHash } from "crypto";
import { existsSync, readFileSync } from "fs";
import { readFile } from "fs/promises";
import { join } from "path";
import {
  addonAssetName, addonRequired, envArgs, parseSanitizer, type Platform, type Sanitizer,
  assetName, DEFAULT_BASE_URL, DEFAULT_REPO, detectPlatform, mirrorUrl, parseEnvJson,
  parsePlatformOverride, parseSha256File, releaseUrl, resolveVersion, TOOL_NAME,
} from "./lib";

async function sha256(path: string): Promise<string> {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

async function fetchJson(url: string, headers: Record<string, string>): Promise<any> {
  const res = await fetch(url, { headers });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return res.json();
}

async function fetchText(url: string): Promise<string> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return res.text();
}

/** Download an archive and its .sha256 from the first URL that works, verifying the checksum. */
async function downloadVerified(urls: string[]): Promise<string> {
  let lastError: unknown;
  for (const url of urls) {
    try {
      const [archive, sumFile] = await Promise.all([tc.downloadTool(url), tc.downloadTool(`${url}.sha256`)]);
      const expected = parseSha256File(await readFile(sumFile, "utf-8"));
      const actual = await sha256(archive);
      if (expected !== actual) throw new Error(`SHA256 mismatch for ${url}: expected ${expected}, got ${actual}`);
      core.info(`Downloaded and verified ${url}`);
      return archive;
    } catch (e) {
      lastError = e;
      core.warning(`Download from ${url} failed: ${e}`);
    }
  }
  throw lastError instanceof Error ? lastError : new Error(String(lastError));
}

async function helperOutput(helper: string, args: string[]): Promise<string> {
  const out = await exec.getExecOutput(helper, args, { silent: true });
  return out.stdout;
}

/** True when the bundle at `root` already carries `sanitizer`'s add-on for its own version. */
function addonInstalled(root: string, sanitizer: Sanitizer): boolean {
  const meta = join(root, "share", "elide-toolchain", "sanitizers", `${sanitizer}.addon.json`);
  if (!existsSync(meta)) return false;
  const version = readFileSync(join(root, "share", "elide-toolchain", "VERSION"), "utf-8").trim();
  return JSON.parse(readFileSync(meta, "utf-8")).version === version;
}

/** Fetch, verify and extract a sanitizer add-on over the bundle at `root`; returns its asset name. */
async function installAddon(
  root: string, sanitizer: Sanitizer, platform: Platform, repo: string, baseUrl: string, localArchive: string,
): Promise<string> {
  const version = readFileSync(join(root, "share", "elide-toolchain", "VERSION"), "utf-8").trim();
  const asset = addonAssetName(version, platform, sanitizer);
  if (!asset) return "";
  if (addonInstalled(root, sanitizer)) {
    core.info(`Sanitizer add-on ${asset} already installed`);
    return asset;
  }
  let archive = localArchive;
  if (archive) {
    core.info(`Installing sanitizer add-on from local archive ${archive}`);
  } else {
    try {
      archive = await downloadVerified([releaseUrl(repo, version, asset), mirrorUrl(baseUrl, version, asset)]);
    } catch (e) {
      if (addonRequired(sanitizer)) throw new Error(`${sanitizer} needs its add-on ${asset}: ${e}`);
      core.warning(`Sanitizer add-on ${asset} unavailable (${e}); libc++ and components stay uninstrumented`);
      return "";
    }
  }
  // The add-on's single root dir is elide-toolchain/, like the bundle's: extract next to it.
  await tc.extractTar(archive, join(root, ".."), ["xJ"]);
  if (!addonInstalled(root, sanitizer)) throw new Error(`${asset} did not install a matching ${sanitizer}.addon.json`);
  return asset;
}

async function run(): Promise<void> {
  try {
    const repo = core.getInput("repo") || DEFAULT_REPO;
    const baseUrl = core.getInput("base-url") || DEFAULT_BASE_URL;
    const token = core.getInput("github-token") || undefined;
    const target = core.getInput("target");
    const sanitizer = parseSanitizer(core.getInput("sanitizer"), target);
    const archiveInput = core.getInput("archive");
    const platform = parsePlatformOverride(
      core.getInput("os"), core.getInput("arch"), detectPlatform(process.platform, process.arch));

    let root: string;
    if (archiveInput) {
      core.info(`Installing from local archive ${archiveInput}`);
      root = join(await tc.extractTar(archiveInput, undefined, ["xJ"]), TOOL_NAME);
    } else {
      const version = await resolveVersion(core.getInput("version"), {
        repo, baseUrl, token, fetchers: { json: fetchJson, text: fetchText }, warn: core.warning,
      });
      const asset = assetName(version, platform);
      const cacheArch = `${platform.os}-${platform.arch}`;
      let cached = tc.find(TOOL_NAME, version, cacheArch);
      if (cached) {
        core.info(`Using cached ${TOOL_NAME} ${version}`);
      } else {
        const archive = await downloadVerified([releaseUrl(repo, version, asset), mirrorUrl(baseUrl, version, asset)]);
        const extracted = await tc.extractTar(archive, undefined, ["xJ"]);
        cached = await tc.cacheDir(extracted, TOOL_NAME, version, cacheArch);
      }
      root = join(cached, TOOL_NAME);
    }

    const helper = join(root, "bin", "elide-toolchain");
    if (!existsSync(helper)) throw new Error(`Bundle is missing ${helper}`);
    core.addPath(join(root, "bin"));

    let addon = "";
    if (sanitizer) {
      addon = await installAddon(root, sanitizer, platform, repo, baseUrl, core.getInput("sanitizer-archive"));
    }
    for (const [k, v] of Object.entries(parseEnvJson(await helperOutput(helper, envArgs(target, sanitizer))))) {
      core.exportVariable(k, v);
    }

    const version = (await helperOutput(helper, ["version"])).trim();
    const targets = (await helperOutput(helper, ["targets"])).split("\n").filter(Boolean);
    core.setOutput("home", root);
    core.setOutput("version", version);
    core.setOutput("targets", JSON.stringify(targets));
    core.setOutput("sanitizer-addon", addon);
    core.info(`${TOOL_NAME} ${version} ready at ${root} (targets: ${targets.join(", ")})`);
  } catch (e) {
    core.setFailed(e instanceof Error ? e.message : String(e));
  }
}

run();
