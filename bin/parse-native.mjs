// Parses the JSX the phone app is built from.
//
// Nothing else does until a build runs, and a build is minutes for the web
// export and over half an hour for Android. A typo in a native screen therefore
// costs a full build to discover, which is the most expensive way this
// repository can tell somebody about a missing bracket.
//
// Parsing only. It says the file is syntactically a module, not that it does
// anything sensible: that is what the build and the app are for.
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";

// The parser lives wherever whoever is running this put it: installed globally
// in the builder image, or npm-installed by a CI step. Named through the
// environment rather than searched for, so a missing dependency is an error
// about the dependency and not a confusing parse failure.
const root = process.env.PARSER_ROOT;
const require = createRequire(root ? `${root}/index.js` : import.meta.url);

let parser;
try {
  parser = require("@babel/parser");
} catch {
  console.error("no @babel/parser. Set PARSER_ROOT, or install it where this can see it.");
  process.exit(2);
}

const files = process.argv.slice(2);

if (files.length === 0) {
  console.error("nothing to parse");
  process.exit(2);
}

let bad = 0;

for (const file of files) {
  try {
    parser.parse(readFileSync(file, "utf8"), { sourceType: "module", plugins: ["jsx"] });
  } catch (error) {
    // The location matters more than the message: "Unexpected token (94:12)" is
    // the whole answer when you can see line 94.
    console.error(`FAIL ${file}: ${error.message}`);
    bad += 1;
  }
}

console.log(`parsed ${files.length} native file(s), ${bad} with errors`);
process.exit(bad === 0 ? 0 : 1);
