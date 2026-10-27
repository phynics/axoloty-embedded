// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Resolve the application selected by a repository profile and reject a
// caller-supplied directory that only has a matching manifest name.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const [profileDirectory, selectedDirectory] = process.argv.slice(2);
if (!profileDirectory) {
  console.error("usage: select-profile-application.mjs profile-directory [application-directory]");
  process.exit(64);
}

try {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const profilePath = path.join(profileDirectory, "profile.json");
  const profile = JSON.parse(fs.readFileSync(profilePath, "utf8"));
  if (typeof profile.application !== "string" || profile.application.length === 0) {
    throw new Error("profile does not select an application");
  }
  if (path.basename(profile.application) !== profile.application) throw new Error("profile application must be a single application name");
  const expected = fs.realpathSync(path.join(repoRoot, "Applications", profile.application));
  const selected = selectedDirectory ? fs.realpathSync(selectedDirectory) : expected;
  if (selected !== expected) throw new Error(`selected application directory does not match profile '${profile.application}'`);
  const manifest = JSON.parse(fs.readFileSync(path.join(expected, "app.json"), "utf8"));
  if (manifest.name !== profile.application) {
    throw new Error(`application manifest does not match profile '${profile.application}'`);
  }
  process.stdout.write(`${expected}\n`);
} catch (error) {
  console.error(`profile application selection: ${error.message}`);
  process.exit(64);
}
