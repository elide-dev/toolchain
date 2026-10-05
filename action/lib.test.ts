import { describe, expect, test } from "bun:test";
import {
  assetName, detectPlatform, mirrorUrl, normalizeVersion, parseEnvJson,
  parsePlatformOverride, parseSha256File, releaseUrl, resolveVersion,
} from "./lib";

describe("platform", () => {
  test("maps node platform/arch", () => {
    expect(detectPlatform("linux", "x64")).toEqual({ os: "linux", arch: "amd64" });
    expect(detectPlatform("darwin", "arm64")).toEqual({ os: "darwin", arch: "arm64" });
  });
  test("rejects unsupported", () => {
    expect(() => detectPlatform("win32", "x64")).toThrow(/Unsupported OS/);
    expect(() => detectPlatform("linux", "ia32")).toThrow(/Unsupported architecture/);
  });
  test("overrides", () => {
    const d = { os: "linux", arch: "amd64" } as const;
    expect(parsePlatformOverride("", "", d)).toEqual(d);
    expect(parsePlatformOverride("darwin", "arm64", d)).toEqual({ os: "darwin", arch: "arm64" });
    expect(() => parsePlatformOverride("windows", "", d)).toThrow(/Invalid os/);
  });
});

describe("versions and urls", () => {
  test("normalizes", () => {
    expect(normalizeVersion("v2026.10.0")).toBe("2026.10.0");
    expect(normalizeVersion(" 2026.10.3\n")).toBe("2026.10.3");
    expect(normalizeVersion("2026.10.0-dev.abc1234")).toBe("2026.10.0-dev.abc1234");
    expect(() => normalizeVersion("1.2.5")).toThrow(/Invalid version/);
  });
  test("asset and urls", () => {
    const a = assetName("2026.10.0", { os: "linux", arch: "arm64" });
    expect(a).toBe("elide-toolchain-2026.10.0-linux-arm64.tar.xz");
    expect(releaseUrl("elide-dev/toolchain", "2026.10.0", a))
      .toBe("https://github.com/elide-dev/toolchain/releases/download/v2026.10.0/" + a);
    expect(mirrorUrl("https://static.example.com/", "2026.10.0", a))
      .toBe("https://static.example.com/toolchain/2026.10.0/" + a);
  });
});

describe("resolveVersion", () => {
  const base = { repo: "elide-dev/toolchain", baseUrl: "https://m.example" };
  test("pinned version skips network", async () => {
    const fetchers = { json: async () => { throw new Error("no"); }, text: async () => { throw new Error("no"); } };
    expect(await resolveVersion("v2026.10.1", { ...base, fetchers })).toBe("2026.10.1");
  });
  test("latest via releases API, with token", async () => {
    let seen: Record<string, string> = {};
    const fetchers = {
      json: async (_u: string, h: Record<string, string>) => { seen = h; return { tag_name: "v2026.11.2" }; },
      text: async () => "",
    };
    expect(await resolveVersion("latest", { ...base, token: "t0k", fetchers })).toBe("2026.11.2");
    expect(seen.Authorization).toBe("Bearer t0k");
  });
  test("falls back to mirror latest.txt", async () => {
    const warnings: string[] = [];
    const fetchers = {
      json: async () => { throw new Error("rate limited"); },
      text: async (u: string) => { expect(u).toBe("https://m.example/toolchain/latest.txt"); return "2026.10.4\n"; },
    };
    expect(await resolveVersion("", { ...base, fetchers, warn: (m) => warnings.push(m) })).toBe("2026.10.4");
    expect(warnings.length).toBe(1);
  });
});

describe("parsers", () => {
  test("sha256 file", () => {
    const h = "a".repeat(64);
    expect(parseSha256File(`${h}  elide-toolchain-x.tar.xz\n`)).toBe(h);
    expect(() => parseSha256File("nope")).toThrow(/Invalid SHA256/);
  });
  test("env json", () => {
    expect(parseEnvJson('{"CC":"/x/bin/cc"}')).toEqual({ CC: "/x/bin/cc" });
    expect(() => parseEnvJson("[]")).toThrow(/not a JSON object/);
    expect(() => parseEnvJson('{"A":1}')).toThrow(/not a string/);
  });
});
