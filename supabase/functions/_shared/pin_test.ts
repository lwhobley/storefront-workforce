import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { isValidPin, isWeakPin, pinFingerprint, randomPin } from "./pin.ts";

Deno.test("obvious PINs are weak", () => {
  for (const pin of ["000000", "111111", "123456", "654321", "121212", "123123", "234567"]) {
    assert(isWeakPin(pin), pin);
  }
  for (const pin of ["480715", "902318", "130579"]) assertFalse(isWeakPin(pin), pin);
});

Deno.test("only 6 digits are valid", () => {
  assert(isValidPin("480715"));
  assertFalse(isValidPin("48071"));
  assertFalse(isValidPin("4807155"));
  assertFalse(isValidPin("48o715"));
  assertFalse(isValidPin(480715));
});

Deno.test("random PINs are 6 digits and never weak", () => {
  for (let i = 0; i < 5000; i++) {
    const pin = randomPin();
    assertEquals(pin.length, 6);
    assert(isValidPin(pin), pin);
  }
});

Deno.test("fingerprints depend on the secret and are stable", async () => {
  Deno.env.set("PIN_SECRET", "a".repeat(40));
  const a = await pinFingerprint("480715");
  assertEquals(a, await pinFingerprint("480715"));
  assertEquals(a.length, 64);
  Deno.env.set("PIN_SECRET", "b".repeat(40));
  assert(a !== await pinFingerprint("480715"));
});
