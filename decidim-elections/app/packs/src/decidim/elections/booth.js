import { findVotingBackend } from "src/decidim/elections/voting_backends";
import { createSubmitStep } from "src/decidim/elections/booth_submit";
import { createQuestionLoader } from "src/decidim/elections/booth_live";
import { createReceiptItemBuilder, createReceiptPanels, showCastFlash } from "src/decidim/elections/booth_receipt";

/**
 * Client-side booth stepper. Shows one question at a time, then the confirm
 * step, then the receipt. Answers never leave the page except through the
 * voting backend's adapter.
 *
 * `prepare()` may return `priorReceipts` and `pendingQuestionIds` for a partial
 * ballot: only pending questions are shown and all receipts are combined.
 * Failed or unconfirmed casts go to the submit step (`booth_submit.js`).
 * Questions that open later are added in place (`booth_live.js`).
 *
 * @param {HTMLElement} root - the `[data-voting-booth]` element.
 * @returns {Promise<void>} resolves once the booth reached its first step.
 */
const initBooth = async (root) => {
  if (root.dataset.boothStarted) {
    return;
  }
  root.dataset.boothStarted = "true";

  const config = JSON.parse(root.dataset.config || "{}");
  const i18n = JSON.parse(root.dataset.i18n || "{}");
  const statusEl = root.querySelector("[data-booth-status]");
  const form = root.querySelector("[data-booth-form]");
  const questions = Array.from(root.querySelectorAll("[data-booth-question]"));
  const preBallot = root.querySelector("[data-booth-step='pre-ballot']");
  const confirm = root.querySelector("[data-booth-step='confirm']");
  const submitStep = root.querySelector("[data-booth-step='submit']");
  const receipt = root.querySelector("[data-booth-step='receipt']");
  const errorStep = root.querySelector("[data-booth-step='error']");

  // Questions for this visit (all, or filtered when resuming a partial ballot).
  let activeQuestions = questions;
  // Receipts from questions cast in a prior visit.
  let priorReceipts = [];

  const progress = (msg) => {
    statusEl.textContent = msg || "";
  };
  const receiptPanels = createReceiptPanels({ receipt, banner: root.querySelector("[data-booth-already-recorded]"), progress, i18n });

  const show = (section) => {
    // Queried each time: `ctx.loadQuestions` adds question steps.
    root.querySelectorAll("[data-booth-step]").forEach((step) => {
      step.hidden = step !== section;
    });
    if (section !== receipt) {
      receiptPanels.leave();
    }
    const heading = section.querySelector("[tabindex='-1']");
    if (heading) {
      heading.focus();
    }
  };

  const fail = (msg) => {
    progress("");
    errorStep.querySelector("[data-booth-error-message]").textContent = msg;
    show(errorStep);
  };

  // Bound below, once the steps and the adapter exist.
  let addNavigationListeners = null;
  let begin = null;

  const ctx = {
    config,
    i18n,
    progress,
    error: fail,
    loadQuestions: createQuestionLoader({ form, questions, onAdded: (sections) => addNavigationListeners(sections) }),
    restart: () => begin(),
    showPanel: () => {
      if (preBallot) {
        show(preBallot);
      }

      return preBallot;
    },
    waiting: receiptPanels.waiting
  };

  const selected = (section) => Array.from(section.querySelectorAll("input:checked")).map((input) => input.value);

  const withinLimit = (section) => {
    const container = section.querySelector(".response[data-max-choices]");
    const max = container && parseInt(container.dataset.maxChoices, 10);

    return !max || selected(section).length <= max;
  };

  const buildReceiptItem = createReceiptItemBuilder(questions, config);

  // `cast` marks a receipt reached by casting now, not by an earlier visit.
  const showReceipt = (receipts, { cast = false } = {}) => {
    const list = receipt.querySelector("[data-booth-receipts]");
    list.innerHTML = "";
    (receipts || []).forEach((item) => list.append(buildReceiptItem(item)));
    receiptPanels.hideBanner();
    progress("");
    if (cast) {
      showCastFlash(root);
    }
    show(receipt);
  };

  const showSubmit = createSubmitStep({
    questions,
    submitStep,
    progress,
    show,
    showReceipt,
    buildReceiptItem,
    selected,
    i18n,
    ctx,
    backendName: root.dataset.votingBackend
  });

  const showConfirm = () => {
    const list = confirm.querySelector("[data-booth-confirm-list]");
    list.innerHTML = "";
    activeQuestions.forEach((section) => {
      const block = document.createElement("div");
      const title = document.createElement("p");
      title.className = "font-semibold mb-2";
      title.textContent = section.dataset.questionTitle;
      block.append(title);
      const chosen = Array.from(section.querySelectorAll("input:checked"));
      if (chosen.length === 0) {
        const none = document.createElement("p");
        none.className = "italic text-gray-500";
        none.textContent = i18n.not_answered;
        block.append(none);
      }
      chosen.forEach((input) => {
        const option = document.createElement("p");
        option.textContent = input.closest("[data-option-title]").dataset.optionTitle;
        block.append(option);
      });
      list.append(block);
    });
    show(confirm);
  };

  const showQuestion = (index) => {
    if (index >= activeQuestions.length) {
      showConfirm();
      return;
    }
    const section = activeQuestions[Math.max(index, 0)];
    const back = section.querySelector("[data-booth-back]");
    if (back) {
      // The server renders "back" by page position; this visit may start later.
      back.style.visibility = section === activeQuestions[0]
        ? "hidden"
        : "";
    }
    // The last question leads to the confirm step, so its button says so.
    const nextLabel = section.querySelector("[data-booth-next-label]");
    if (nextLabel && i18n.review) {
      nextLabel.textContent = section === activeQuestions[activeQuestions.length - 1]
        ? i18n.review
        : i18n.next;
    }
    show(section);
  };

  const step = (section, offset) => showQuestion(activeQuestions.indexOf(section) + offset);

  /**
   * Attaches next/back navigation listeners to a question section list.
   *
   * @param {HTMLElement[]} qList - question sections to wire up.
   * @returns {void}
   */
  addNavigationListeners = (qList) => {
    qList.forEach((section) => {
      const container = section.querySelector(".response[data-max-choices]");
      const alertEl = section.querySelector(".max-choices-alert");
      section.querySelectorAll("input[type=checkbox]").forEach((checkbox) => {
        checkbox.addEventListener("change", () => {
          if (container && alertEl) {
            alertEl.style.display = withinLimit(section)
              ? "none"
              : "block";
          }
        });
      });
      const back = section.querySelector("[data-booth-back]");
      if (back) {
        back.addEventListener("click", () => step(section, -1));
      }
      section.querySelector("[data-booth-next]").addEventListener("click", () => {
        if (!withinLimit(section)) {
          progress(i18n.max_choices_alert);
          return;
        }
        progress("");
        step(section, 1);
      });
    });
  };

  addNavigationListeners(questions);
  confirm.querySelector("[data-booth-edit]").addEventListener("click", () => showQuestion(0));

  let adapter = null;
  try {
    adapter = await findVotingBackend(root.dataset.votingBackend);
  } catch {
    fail(i18n.backend_missing);
    return;
  }

  const castButton = confirm.querySelector("[data-booth-cast]");
  castButton.addEventListener("click", async () => {
    castButton.disabled = true;
    progress(i18n.casting);
    const ballot = activeQuestions.map((section) => ({
      questionId: section.dataset.questionId,
      responseOptionIds: selected(section)
    }));
    const result = await adapter.cast(ctx, ballot);
    const allConfirmed = [...priorReceipts, ...result.receipts];
    if (result.unconfirmed.length === 0 && result.failed.length === 0) {
      showReceipt(allConfirmed, { cast: true });
    } else {
      showSubmit({ confirmed: allConfirmed, unconfirmed: result.unconfirmed, failed: result.failed });
    }
    castButton.disabled = false;
  });

  begin = async () => {
    activeQuestions = questions;
    priorReceipts = [];
    receiptPanels.hideBanner();
    try {
      const state = await adapter.prepare(ctx);
      if (state.alreadyVoted) {
        showReceipt(state.receipts);
        return;
      }
      if (!state.canVote) {
        fail(state.message || i18n.cannot_vote);
        return;
      }

      // Handle partial ballot (some questions already cast in a prior visit).
      if (state.priorReceipts && state.priorReceipts.length > 0) {
        priorReceipts = state.priorReceipts;
        const pendingIds = state.pendingQuestionIds || [];
        activeQuestions = questions.filter((sect) => pendingIds.includes(sect.dataset.questionId));
        receiptPanels.showBanner();
      }

      progress("");
      showQuestion(0);
    } catch (error) {
      fail(error.message);
    }
  };

  await begin();
};

const start = () => document.querySelectorAll("[data-voting-booth]").forEach((root) => initBooth(root));

document.addEventListener("turbo:load", start);
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
