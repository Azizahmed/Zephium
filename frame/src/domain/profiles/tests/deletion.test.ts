import { beforeEach, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({
  settle: vi.fn(),
  waitForDisposition: vi.fn(),
  forgetDrafts: vi.fn(),
  profilesDelete: vi.fn(),
  onDisposition: vi.fn(),
  result: vi.fn(),
}));
vi.mock("$domain/operations", () => ({
  settle: mocks.settle,
  operations: {
    waitForDisposition: mocks.waitForDisposition,
    onDisposition: mocks.onDisposition,
    result: mocks.result,
  },
}));
vi.mock("$shared/ipc/bindings", () => ({ commands: { profilesDelete: mocks.profilesDelete } }));
vi.mock("$shared/ipc/native-events", () => ({ events: {} }));
vi.mock("$shared/lib/drafts", () => ({ forgetDrafts: mocks.forgetDrafts }));
import { release, remove } from "../profiles.svelte";
beforeEach(() => {
  vi.resetAllMocks();
  mocks.onDisposition.mockReturnValue(() => {});
});
it("keeps unresolved deletion pending and observes its original operation on retry", async () => {
  mocks.settle.mockResolvedValue({
    outcome: "failed",
    reason: "unresolved",
    operation_id: "0000000000000001",
  });
  await expect(remove("profile")).resolves.toEqual({
    state: "pending",
    operation_id: "0000000000000001",
  });
  expect(mocks.forgetDrafts).not.toHaveBeenCalled();
  mocks.waitForDisposition.mockResolvedValue({
    state: "processed",
    disposition: {
      operation_id: "0000000000000001",
      outcome: "applied",
      reason: "profile_deletion_completed",
    },
  });
  await expect(remove("profile", "0000000000000001")).resolves.toEqual({ state: "completed" });
  expect(mocks.profilesDelete).toHaveBeenCalledTimes(1);
  expect(mocks.forgetDrafts).toHaveBeenCalledWith("profile");
});
it("never treats a deferred deletion as completed", async () => {
  mocks.settle.mockResolvedValue({
    outcome: "deferred",
    disposition: { operation_id: "0000000000000001" },
  });
  await expect(remove("profile")).resolves.toMatchObject({ state: "pending" });
  expect(mocks.forgetDrafts).not.toHaveBeenCalled();
});

it("forgets drafts when deletion completes after the profiles sheet closes", async () => {
  mocks.settle.mockResolvedValue({
    outcome: "failed",
    reason: "unresolved",
    operation_id: "0000000000000002",
  });
  await expect(remove("late-profile")).resolves.toMatchObject({ state: "pending" });
  release();
  expect(mocks.forgetDrafts).not.toHaveBeenCalled();
  const notify = mocks.onDisposition.mock.calls.at(-1)?.[1];
  expect(notify).toBeTypeOf("function");
  notify({
    operation_id: "0000000000000003",
    outcome: "applied",
    reason: "profile_deletion_completed",
  });
  expect(mocks.forgetDrafts).not.toHaveBeenCalled();
  notify({
    operation_id: "0000000000000002",
    outcome: "applied",
    reason: "profile_deletion_completed",
  });
  expect(mocks.forgetDrafts).toHaveBeenCalledExactlyOnceWith("late-profile");
  notify({
    operation_id: "0000000000000002",
    outcome: "applied",
    reason: "profile_deletion_completed",
  });
  expect(mocks.forgetDrafts).toHaveBeenCalledTimes(1);
});

it("releases a rejected pending deletion without erasing drafts", async () => {
  mocks.settle.mockResolvedValue({
    outcome: "failed",
    reason: "unresolved",
    operation_id: "0000000000000004",
  });
  await remove("rejected-profile");
  const notify = mocks.onDisposition.mock.calls.at(-1)?.[1];
  notify({ operation_id: "0000000000000004", outcome: "rejected", reason: "store_conflict" });
  expect(mocks.forgetDrafts).not.toHaveBeenCalled();
  notify({
    operation_id: "0000000000000004",
    outcome: "applied",
    reason: "profile_deletion_completed",
  });
  expect(mocks.forgetDrafts).not.toHaveBeenCalled();
});
