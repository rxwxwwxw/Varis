// Optional maintenance build; normal Varis builds embed the checked-in bundle.
import { build } from "esbuild";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
const root = dirname(fileURLToPath(import.meta.url));
const result = await build({ entryPoints: [join(root, "main.js")], outfile: resolve(root, "../editor.bundle.js"),
  bundle: true, format: "iife", globalName: "VarisEditor", minify: true, legalComments: "eof", metafile: true, charset: "utf8" });
const packages = new Map();
for (const input of Object.keys(result.metafile.inputs)) {
  let directory = dirname(resolve(input));
  while (directory !== dirname(directory)) {
    try {
      const p = JSON.parse(await readFile(join(directory, "package.json"), "utf8"));
      if (p.name && p.version) {
        if (!packages.has(p.name)) {
          const license = await readFile(join(directory, "LICENSE"), "utf8");
          packages.set(p.name, `${p.name} ${p.version}\n${license.trim()}\n`);
        }
        break;
      }
    } catch {}
    directory = dirname(directory);
  }
}
const notices = [...packages].sort(([a], [b]) => a.localeCompare(b)).map(([, text]) => text).join("\n---\n\n");
await writeFile(resolve(root, "../THIRD_PARTY_NOTICES.txt"), notices);
const bundle = resolve(root, "../editor.bundle.js");
await writeFile(bundle, "/* Third-party notices\n" + notices + "*/\n" + await readFile(bundle, "utf8"));
