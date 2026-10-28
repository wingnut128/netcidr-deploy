import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.13";
import { decide } from "./release_watch.ts";

const release = {
  tag: "v0.34.0",
  url: "https://github.com/wingnut128/netcidr/releases/tag/v0.34.0",
};

Deno.test("announces a new release that is not deployed yet", () => {
  const d = decide(release, "0.33.5", "v0.33.5");
  assertEquals(d.pending, true);
  assertEquals(d.needsNotify, true);
  assertStringIncludes(d.message, "released but not deployed (live: v0.33.5)");
  assertStringIncludes(d.message, "swamp workflow run deploy");
});

Deno.test("announces a new release that is already live", () => {
  const d = decide(release, "0.34.0", "v0.33.5");
  assertEquals(d.pending, false);
  assertEquals(d.needsNotify, true);
  assertEquals(
    d.message,
    `netcidr v0.34.0 is released and already live. ${release.url}`,
  );
});

Deno.test("does not announce a release twice", () => {
  assertEquals(decide(release, "0.33.5", "v0.34.0").needsNotify, false);
  assertEquals(decide(release, "0.34.0", "v0.34.0").needsNotify, false);
});

Deno.test("announces on the first check, before anything was recorded", () => {
  assertEquals(decide(release, "0.34.0", "").needsNotify, true);
});
