export type Os = "linux" | "darwin";
export type Arch = "amd64" | "arm64";
export interface Platform { os: Os; arch: Arch }

export const TOOL_NAME = "elide-toolchain";
export const DEFAULT_REPO = "elide-dev/toolchain";
export const DEFAULT_BASE_URL = "https://static.elideusercontent.com";

export function detectPlatform(platform: string, arch: string): Platform {
  const os: Os | null = platform === "linux" ? "linux" : platform === "darwin" ? "darwin" : null;
  if (!os) throw new Error(`Unsupported OS: ${platform} (supported: linux, darwin)`);
  const a: Arch | null = arch === "x64" ? "amd64" : arch === "arm64" ? "arm64" : null;
  if (!a) throw new Error(`Unsupported architecture: ${arch} (supported: x64, arm64)`);
  return { os, arch: a };
}

export function parsePlatformOverride(os: string, arch: string, detected: Platform): Platform {
  const o = os || detected.os;
  const a = arch || detected.arch;
  if (o !== "linux" && o !== "darwin") throw new Error(`Invalid os input: ${o} (linux or darwin)`);
  if (a !== "amd64" && a !== "arm64") throw new Error(`Invalid arch input: ${a} (amd64 or arm64)`);
  return { os: o, arch: a };
}

export function normalizeVersion(v: string): string {
  const s = v.trim().replace(/^v/, "");
  if (!/^\d{4}\.\d{1,2}\.\d+([-+][0-9A-Za-z.-]+)?$/.test(s)) {
    throw new Error(`Invalid version: ${v} (expected YYYY.MM.N or 'latest')`);
  }
  return s;
}

export function assetName(version: string, p: Platform): string {
  return `${TOOL_NAME}-${version}-${p.os}-${p.arch}.tar.xz`;
}

export function releaseUrl(repo: string, version: string, asset: string): string {
  return `https://github.com/${repo}/releases/download/v${version}/${asset}`;
}

export function mirrorUrl(baseUrl: string, version: string, asset: string): string {
  return `${baseUrl.replace(/\/+$/, "")}/toolchain/${version}/${asset}`;
}

export interface Fetchers {
  json(url: string, headers: Record<string, string>): Promise<any>;
  text(url: string): Promise<string>;
}

export interface ResolveOptions {
  repo: string;
  baseUrl: string;
  token?: string;
  fetchers: Fetchers;
  warn?: (message: string) => void;
}

export async function resolveVersion(input: string, opts: ResolveOptions): Promise<string> {
  const want = (input || "latest").trim();
  if (want !== "latest") return normalizeVersion(want);
  try {
    const headers: Record<string, string> = { Accept: "application/vnd.github+json" };
    if (opts.token) headers.Authorization = `Bearer ${opts.token}`;
    const release = await opts.fetchers.json(`https://api.github.com/repos/${opts.repo}/releases/latest`, headers);
    return normalizeVersion(String(release.tag_name));
  } catch (e) {
    opts.warn?.(`GitHub Releases lookup failed (${e}); falling back to mirror`);
    const text = await opts.fetchers.text(`${opts.baseUrl.replace(/\/+$/, "")}/toolchain/latest.txt`);
    return normalizeVersion(text);
  }
}

export function parseSha256File(content: string): string {
  const hash = (content.trim().split(/\s+/)[0] ?? "").toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(hash)) throw new Error(`Invalid SHA256 file content: ${content}`);
  return hash;
}

export function parseEnvJson(text: string): Record<string, string> {
  const obj: unknown = JSON.parse(text);
  if (typeof obj !== "object" || obj === null || Array.isArray(obj)) throw new Error("env output is not a JSON object");
  for (const [k, v] of Object.entries(obj)) {
    if (typeof v !== "string") throw new Error(`env value for ${k} is not a string`);
  }
  return obj as Record<string, string>;
}
