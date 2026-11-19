/* global jest */

import { booth, flush, mountBooth, visible } from "src/decidim/elections/booth_test_helpers";

const el = (selector) => document.querySelector(selector);
const label = (id) => el(`[data-question-id='${id}'] [data-booth-next-label]`).textContent;

const castAll = async () => {
  visible()[0].querySelector("[data-booth-next]").click();
  el("[data-booth-cast]").click();
  await flush();
};

describe("next button label", () => {
  it("says next on earlier questions and review on the last one, also after going back", async () => {
    await mountBooth(["1", "2"]);
    expect(label("1")).toBe("next");

    el("[data-question-id='1'] [data-booth-next]").click();
    expect(label("2")).toBe("review");

    el("[data-question-id='2'] [data-booth-back]").click();
    expect(label("1")).toBe("next");
  });

  it("says review when the booth has a single question", async () => {
    await mountBooth(["1"]);
    expect(label("1")).toBe("review");
  });
});

describe("already-recorded banner", () => {
  const partial = { canVote: true, alreadyVoted: false, priorReceipts: [{ questionId: "1", code: "0xaa" }], pendingQuestionIds: ["2"] };

  it("is shown while voting the pending questions and hidden on the receipt", async () => {
    await mountBooth(["1", "2"], partial);
    expect(el("[data-booth-already-recorded]").hidden).toBe(false);

    await castAll();
    expect(visible()[0].dataset.boothStep).toBe("receipt");
    expect(el("[data-booth-already-recorded]").hidden).toBe(true);
  });

  it("is hidden when the booth restarts without prior receipts", async () => {
    const { adapter, ctx } = await mountBooth(["1", "2"], partial);
    adapter.prepare.mockResolvedValueOnce({ canVote: true, alreadyVoted: false });

    await ctx().restart();
    expect(el("[data-booth-already-recorded]").hidden).toBe(true);
  });
});

describe("receipt step", () => {
  const flashes = () => document.querySelectorAll("#flash-messages-container .flash");

  it("lists each receipt with its question title and code", async () => {
    await mountBooth(["1", "2"]);
    el("[data-question-id='1'] [data-booth-next]").click();
    await castAll();

    const blocks = Array.from(el("[data-booth-receipts]").children);
    expect(blocks.map((block) => block.querySelector("p").textContent)).toEqual(["Q1", "Q2"]);
    expect(blocks.map((block) => block.querySelector("p[title]").textContent)).toEqual(["0x1", "0x2"]);
  });

  it("shows the cast success flash once, also after a later cast", async () => {
    await mountBooth(["1"]);
    await castAll();
    expect(flashes()).toHaveLength(1);
    expect(flashes()[0].textContent).toBe("cast ok");

    el("[data-booth-cast]").click();
    await flush();
    expect(flashes()).toHaveLength(1);
  });

  it("shows no flash when the voter had already voted", async () => {
    await mountBooth(["1"], { canVote: true, alreadyVoted: true, receipts: [{ questionId: "1", code: "0x1" }] });
    expect(visible()[0].dataset.boothStep).toBe("receipt");
    expect(flashes()).toHaveLength(0);
  });
});

describe("ctx.waiting", () => {
  it("toggles the waiting panel and the success header on the receipt step", async () => {
    const { ctx } = await mountBooth(["1"]);
    await castAll();
    ctx().progress("some status");

    ctx().waiting(true);
    expect(el("[data-booth-waiting]").hidden).toBe(false);
    expect(el("[data-booth-receipt-header]").hidden).toBe(true);
    expect(el("[data-booth-status]").textContent).toBe("");

    ctx().waiting(false);
    expect(el("[data-booth-waiting]").hidden).toBe(true);
    expect(el("[data-booth-receipt-header]").hidden).toBe(false);
  });

  it("uses the status line while the receipt step is not visible", async () => {
    const { ctx } = await mountBooth(["1"]);

    ctx().waiting(true);
    expect(el("[data-booth-status]").textContent).toBe("Waiting");
    expect(el("[data-booth-waiting]").hidden).toBe(true);

    ctx().waiting(false);
    expect(el("[data-booth-status]").textContent).toBe("");
  });

  it("hides the panel and restores the header when a new question opens in place", async () => {
    const { adapter, ctx } = await mountBooth(["1"]);
    await castAll();
    ctx().waiting(true);

    window.fetch = jest.fn().mockResolvedValue({
      ok: true,
      text: () => Promise.resolve(`<html><body>${booth(["1", "2"])}</body></html>`)
    });
    adapter.prepare.mockResolvedValueOnce({ canVote: true, alreadyVoted: false, priorReceipts: [{ questionId: "1", code: "0x1" }], pendingQuestionIds: ["2"] });
    await ctx().loadQuestions("/booth");
    await ctx().restart();
    Reflect.deleteProperty(window, "fetch");

    expect(visible()[0].dataset.questionId).toBe("2");
    expect(el("[data-booth-waiting]").hidden).toBe(true);
    expect(el("[data-booth-receipt-header]").hidden).toBe(false);
  });
});
