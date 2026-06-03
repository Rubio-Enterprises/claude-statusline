import { defineConfig } from "@playwright/test";

const parseShard = (s: string) => {
  const [n, total] = s.split("/").map(Number);
  return { current: n, total };
};

export default defineConfig({
  testDir: "./tests/e2e",
  reporter: [["list"], ["junit", { outputFile: "reports/e2e/junit.xml" }]],
  outputDir: "reports/e2e/traces",
  retries: Number(process.env.PW_RETRIES ?? (process.env.CI ? 2 : 0)),
  ...(process.env.PW_SHARD ? { shard: parseShard(process.env.PW_SHARD) } : {}),
  use: {
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },
});
