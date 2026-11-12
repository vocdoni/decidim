/* global jest */

const question = (id, index) => `
  <section data-booth-step="question" data-booth-question data-question-id="${id}" data-question-title="Q${id}" hidden>
    <h1 tabindex="-1">Q${id}</h1>
    <div class="response"><label data-option-title="Yes"><input type="checkbox" value="${id}0"></label></div>
    ${index > 0
    ? "<button type=\"button\" data-booth-back>back</button>"
    : ""}
    <button type="button" data-booth-next><span data-booth-next-label>next</span></button>
  </section>`;

const booth = (ids, { reviewLabel = "review", waitingTitle = "Waiting" } = {}) => `
  <div data-voting-booth data-voting-backend="fake" data-config='{"questions":${JSON.stringify(ids)}}' data-i18n='${JSON.stringify({ next: "next", review: reviewLabel, not_answered: "none", casting: "casting", waiting: { cast: "cast", title: waitingTitle, description: "desc" } })}'>
    <div data-booth-status></div>
    <section data-booth-step="loading"></section>
    <section data-booth-step="error" hidden><div data-booth-error-message></div></section>
    <form data-booth-form>
      <div data-booth-already-recorded hidden></div>
      ${ids.map(question).join("")}
    </form>
    <section data-booth-step="confirm" hidden>
      <div data-booth-confirm-list></div>
      <button type="button" data-booth-edit>edit</button>
      <button type="button" data-booth-cast>cast</button>
    </section>
    <section data-booth-step="submit" hidden>
      <h3 data-booth-submit-title></h3><p data-booth-submit-summary></p><ul data-booth-submit-list></ul>
      <button type="button" data-booth-retry hidden></button><button type="button" data-booth-recheck hidden></button>
    </section>
    <section data-booth-step="receipt" hidden>
      <div data-booth-receipt-header></div>
      <div data-booth-waiting hidden></div>
      <ul data-booth-receipts></ul>
    </section>
  </div>`;

const flush = async () => {
  for (let tick = 0; tick < 5; tick += 1) {
    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });
  }
};

const visible = () => Array.from(document.querySelectorAll("[data-booth-step]")).filter((step) => !step.hidden);

describe("client-side booth with questions that open later", () => {
  let adapter = null;
  let ctx = null;

  beforeEach(async () => {
    document.body.innerHTML = booth(["1"]);
    adapter = {
      prepare: jest.fn(async (context) => {
        ctx = context;

        return { canVote: true, alreadyVoted: false };
      }),
      cast: jest.fn(async () => ({ receipts: [{ questionId: "1", code: "0xaa" }], unconfirmed: [], failed: [] }))
    };
    window.Decidim = { votingBackends: { fake: adapter } };
    jest.isolateModules(() => {
      // eslint-disable-next-line global-require -- the booth starts on import, after the DOM is set up
      require("src/decidim/elections/booth");
    });
    await flush();
  });

  afterEach(() => {
    Reflect.deleteProperty(window, "fetch");
  });

  it("adds the new question in place and votes it after a restart", async () => {
    document.querySelector("[data-booth-next]").click();
    document.querySelector("[data-booth-cast]").click();
    await flush();
    expect(visible().map((step) => step.dataset.boothStep)).toEqual(["receipt"]);

    window.fetch = jest.fn().mockResolvedValue({
      ok: true,
      text: () => Promise.resolve(`<html><body>${booth(["1", "2"])}</body></html>`)
    });
    adapter.prepare.mockResolvedValueOnce({
      canVote: true,
      alreadyVoted: false,
      priorReceipts: [{ questionId: "1", code: "0xaa" }],
      pendingQuestionIds: ["2"]
    });

    const loaded = await ctx.loadQuestions("/booth");
    await ctx.restart();

    expect(loaded.questionIds).toEqual(["2"]);
    expect(adapter.prepare).toHaveBeenCalledTimes(2);
    const shown = visible();
    expect(shown).toHaveLength(1);
    expect(shown[0].dataset.questionId).toBe("2");
    // First question of this visit: nothing to go back to.
    expect(shown[0].querySelector("[data-booth-back]").style.visibility).toBe("hidden");

    shown[0].querySelector("[data-booth-next]").click();
    adapter.cast.mockResolvedValueOnce({ receipts: [{ questionId: "2", code: "0xbb" }], unconfirmed: [], failed: [] });
    document.querySelector("[data-booth-cast]").click();
    await flush();

    expect(adapter.cast).toHaveBeenLastCalledWith(ctx, [{ questionId: "2", responseOptionIds: [] }]);
    const codes = Array.from(document.querySelectorAll("[data-booth-receipts] code")).map((code) => code.textContent);
    expect(codes).toEqual(["0xaa", "0xbb"]);
  });
});

describe("review label on last active question", () => {
  let ctx = null;

  beforeEach(async () => {
    document.body.innerHTML = booth(["1", "2"]);
    window.Decidim = {
      votingBackends: {
        fake: {
          prepare: jest.fn(async (context) => {
            ctx = context;

            return { canVote: true, alreadyVoted: false };
          }),
          cast: jest.fn(async () => ({ receipts: [], unconfirmed: [], failed: [] }))
        }
      }
    };
    jest.isolateModules(() => {
      require("src/decidim/elections/booth");
    });
    await flush();
  });

  it("first question shows next label", () => {
    const q1 = document.querySelector("[data-question-id='1']");
    expect(q1.hidden).toBe(false);
    expect(q1.querySelector("[data-booth-next-label]").textContent).toBe("next");
  });

  it("last question shows review label after navigating to it", async () => {
    document.querySelector("[data-question-id='1'] [data-booth-next]").click();
    await flush();
    const q2 = document.querySelector("[data-question-id='2']");
    expect(q2.hidden).toBe(false);
    expect(q2.querySelector("[data-booth-next-label]").textContent).toBe("review");
  });

  it("when going back, first question shows next label again", async () => {
    document.querySelector("[data-question-id='1'] [data-booth-next]").click();
    await flush();
    document.querySelector("[data-question-id='2'] [data-booth-back]").click();
    await flush();
    const q1 = document.querySelector("[data-question-id='1']");
    expect(q1.hidden).toBe(false);
    expect(q1.querySelector("[data-booth-next-label]").textContent).toBe("next");
  });

  it("single-question booth: the only question shows review label", async () => {
    document.body.innerHTML = booth(["1"]);
    window.Decidim = {
      votingBackends: {
        fake: {
          prepare: jest.fn(async (c) => {
            ctx = c;

            return { canVote: true, alreadyVoted: false };
          }),
          cast: jest.fn(async () => ({ receipts: [], unconfirmed: [], failed: [] }))
        }
      }
    };
    jest.isolateModules(() => {
      require("src/decidim/elections/booth");
    });
    await flush();
    const q1 = document.querySelector("[data-question-id='1']");
    expect(q1.querySelector("[data-booth-next-label]").textContent).toBe("review");
  });
});

describe("already-recorded banner hidden on receipt", () => {
  let adapter = null;
  let ctx = null;

  beforeEach(async () => {
    document.body.innerHTML = booth(["1", "2"]);
    adapter = {
      prepare: jest.fn(async (context) => {
        ctx = context;

        return {
          canVote: true,
          alreadyVoted: false,
          priorReceipts: [{ questionId: "1", code: "0xaa" }],
          pendingQuestionIds: ["2"]
        };
      }),
      cast: jest.fn(async () => ({ receipts: [{ questionId: "2", code: "0xbb" }], unconfirmed: [], failed: [] }))
    };
    window.Decidim = { votingBackends: { fake: adapter } };
    jest.isolateModules(() => {
      require("src/decidim/elections/booth");
    });
    await flush();
  });

  it("shows the already-recorded banner during voting", () => {
    const banner = document.querySelector("[data-booth-already-recorded]");
    expect(banner.hidden).toBe(false);
  });

  it("hides the already-recorded banner after receipt is shown", async () => {
    document.querySelector("[data-booth-next]").click();
    document.querySelector("[data-booth-cast]").click();
    await flush();
    const banner = document.querySelector("[data-booth-already-recorded]");
    expect(banner.hidden).toBe(true);
  });

  it("resets the already-recorded banner at the start of begin", async () => {
    // After the initial begin, banner is visible.
    expect(document.querySelector("[data-booth-already-recorded]").hidden).toBe(false);
    // A second begin without prior receipts should reset it.
    adapter.prepare.mockResolvedValueOnce({ canVote: true, alreadyVoted: false });
    await ctx.restart();
    await flush();
    expect(document.querySelector("[data-booth-already-recorded]").hidden).toBe(true);
  });
});

describe("ctx.waiting shows and hides the waiting panel", () => {
  let ctx = null;

  beforeEach(async () => {
    document.body.innerHTML = booth(["1"]);
    window.Decidim = {
      votingBackends: {
        fake: {
          prepare: jest.fn(async (context) => {
            ctx = context;

            return { canVote: true, alreadyVoted: false };
          }),
          cast: jest.fn(async () => ({ receipts: [{ questionId: "1", code: "0xaa" }], unconfirmed: [], failed: [] }))
        }
      }
    };
    jest.isolateModules(() => {
      require("src/decidim/elections/booth");
    });
    await flush();
  });

  it("ctx.waiting is defined on the context", () => {
    expect(typeof ctx.waiting).toBe("function");
  });

  it("ctx.waiting(true) shows the waiting panel and hides the receipt header", async () => {
    document.querySelector("[data-booth-next]").click();
    document.querySelector("[data-booth-cast]").click();
    await flush();
    expect(visible()[0].dataset.boothStep).toBe("receipt");

    ctx.waiting(true);
    expect(document.querySelector("[data-booth-waiting]").hidden).toBe(false);
    expect(document.querySelector("[data-booth-receipt-header]").hidden).toBe(true);
  });

  it("ctx.waiting(false) hides the waiting panel", async () => {
    document.querySelector("[data-booth-next]").click();
    document.querySelector("[data-booth-cast]").click();
    await flush();

    ctx.waiting(true);
    ctx.waiting(false);
    expect(document.querySelector("[data-booth-waiting]").hidden).toBe(true);
    expect(document.querySelector("[data-booth-receipt-header]").hidden).toBe(false);
  });

  it("navigating to a non-receipt step hides the waiting panel", async () => {
    document.querySelector("[data-booth-next]").click();
    document.querySelector("[data-booth-cast]").click();
    await flush();

    ctx.waiting(true);
    // Cast again triggers restart path; simulate navigating back to a question step.
    window.fetch = jest.fn().mockResolvedValue({
      ok: true,
      text: () => Promise.resolve(`<html><body>${booth(["1", "2"])}</body></html>`)
    });
    // Trigger show on a question step by calling restart.
    window.Decidim.votingBackends.fake.prepare.mockResolvedValueOnce({
      canVote: true,
      alreadyVoted: false
    });
    await ctx.loadQuestions("/booth");
    await ctx.restart();
    await flush();

    expect(document.querySelector("[data-booth-waiting]").hidden).toBe(true);
  });

  it("ctx.waiting(true) clears the status line", async () => {
    document.querySelector("[data-booth-next]").click();
    document.querySelector("[data-booth-cast]").click();
    await flush();

    // Set a status message then activate waiting.
    ctx.progress("some status");
    ctx.waiting(true);
    expect(document.querySelector("[data-booth-status]").textContent).toBe("");
  });
});
