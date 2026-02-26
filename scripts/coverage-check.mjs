#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const lcovPath = process.argv[2] ?? "coverage/lcov.info";

if (!fs.existsSync(lcovPath)) {
  console.error(`LCOV file not found: ${lcovPath}`);
  process.exit(1);
}

const data = fs.readFileSync(lcovPath, "utf8");
const lines = data.split(/\r?\n/);

const repoRoot = process.cwd().replace(/\\/g, "/");
const repoSrcPrefix = `${repoRoot}/src/`;

const isIncludedFile = (filePath) => {
  const normalized = path.posix
    .normalize(filePath.replace(/\\/g, "/"))
    .replace(/^\.\/+/, "");
  return (
    normalized.endsWith(".sol") &&
    (normalized.startsWith("src/") || normalized.startsWith(repoSrcPrefix))
  );
};

let include = false;
let linesFound = 0;
let linesHit = 0;
let branchesFound = 0;
let branchesHit = 0;

for (const line of lines) {
  if (line.startsWith("SF:")) {
    const filePath = line.slice(3).trim();
    include = isIncludedFile(filePath);
    continue;
  }

  if (line === "end_of_record") {
    include = false;
    continue;
  }

  if (!include) continue;

  if (line.startsWith("DA:")) {
    const parts = line.slice(3).split(",");
    if (parts.length >= 2) {
      const count = Number(parts[1]);
      linesFound += 1;
      if (count > 0) linesHit += 1;
    }
    continue;
  }

  if (line.startsWith("BRDA:")) {
    const parts = line.slice(5).split(",");
    if (parts.length >= 4) {
      const countStr = parts[3];
      const count = countStr === "-" ? 0 : Number(countStr);
      branchesFound += 1;
      if (count > 0) branchesHit += 1;
    }
  }
}

const pct = (hit, found) => {
  if (found === 0) return 100;
  return Math.round((hit / found) * 10000) / 100;
};

const linePct = pct(linesHit, linesFound);
const branchPct = pct(branchesHit, branchesFound);

const minLines = Number(process.env.COVERAGE_LINES_MIN ?? "0");
const minBranches = Number(process.env.COVERAGE_BRANCHES_MIN ?? "0");

if (Number.isNaN(minLines) || Number.isNaN(minBranches)) {
  console.error("COVERAGE_LINES_MIN and COVERAGE_BRANCHES_MIN must be numbers.");
  process.exit(1);
}

console.log(`Solidity line coverage: ${linesHit}/${linesFound} (${linePct}%)`);
console.log(`Solidity branch coverage: ${branchesHit}/${branchesFound} (${branchPct}%)`);
console.log(`Minimums - lines: ${minLines}%, branches: ${minBranches}%`);

let failed = false;
if (linePct < minLines) {
  console.error(`Line coverage ${linePct}% is below minimum ${minLines}%.`);
  failed = true;
}
if (branchPct < minBranches) {
  console.error(`Branch coverage ${branchPct}% is below minimum ${minBranches}%.`);
  failed = true;
}

process.exit(failed ? 1 : 0);
