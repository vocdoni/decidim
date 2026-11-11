import { findVotingBackend } from "src/decidim/elections/voting_backends";
import { createSubmitStep } from "src/decidim/elections/booth_submit";

/**
 * Client-side booth stepper. Shows one question at a time, then the confirm
 * step, then the receipt. Answers never leave the page except through the
 * voting backend's adapter.
 *
 * The adapter may return `priorReceipts` and `pendingQuestionIds` from
 * `prepare()` when the voter has already cast some questions: in that case the
 * booth presents only the pending questions and combines all receipts at the
 * end. When some questions fail or remain unconfirmed after casting, the submit
 * step (see `booth_submit.js`) shows per-question status with retry/recheck.
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
  const steps = Array.from(root.querySelectorAll("[data-booth-step]"));
  const questions = Array.from(root.querySelectorAll("[data-booth-question]"));
  const preBallot = root.querySelector("[data-booth-step='pre-ballot']");
  const confirm = root.querySelector("[data-booth-step='confirm']");
  const submitStep = root.querySelector("[data-booth-step='submit']");
  const receipt = root.querySelector("[data-booth-step='receipt']");
  const errorStep = root.querySelector("[data-booth-step='error']");
  const alreadyRecordedBanner = root.querySelector("[data-booth-already-recorded]");

  // Questions for this visit (all, or filtered when resuming a partial ballot).
  let activeQuestions = questions;
  // Receipts from questions cast in a prior visit.
  let priorReceipts = [];

  const show = (section) => {
    steps.forEach((step) => {
      step.hidden = step !== section;
    });
    const heading = section.querySelector("[tabindex='-1']");
    if (heading) {
      heading.focus();
    }
  };

  const progress = (msg) => {
    statusEl.textContent = msg || "";
  };

  const fail = (msg) => {
    progress("");
    errorStep.querySelector("[data-booth-error-message]").textContent = msg;
    show(errorStep);
  };

  const ctx = {
    config,
    i18n,
    progress,
    error: fail,
    showPanel: () => {
      if (preBallot) {
        show(preBallot);
      }

      return preBallot;
    }
  };

  const selected = (section) => Array.from(section.querySelectorAll("input:checked")).map((input) => input.value);

  const withinLimit = (section) => {
    const container = section.querySelector(".response[data-max-choices]");
    const max = container && parseInt(container.dataset.maxChoices, 10);

    return !max || selected(section).length <= max;
  };

  // One receipt per question, laid out like the confirm step's answer list.
  const buildReceiptItem = (item) => {
    const qSection = questions.find((sect) => sect.dataset.questionId === String(item.questionId));
    const block = document.createElement("div");
    const title = document.createElement("p");
    title.className = "font-semibold mb-2";
    title.textContent = qSection
      ? qSection.dataset.questionTitle
      : String(item.questionId);
    const code = document.createElement("p");
    code.className = "truncate font-mono text-sm text-gray-2";
    code.title = item.code;
    code.textContent = item.code;
    block.append(title, code);
    if (item.verifyUrl) {
      const link = document.createElement("a");
      link.href = item.verifyUrl;
      link.target = "_blank";
      link.rel = "noopener";
      link.className = "button button__sm button__text-secondary mt-2";
      link.textContent = config.i18n && config.i18n.receipt && config.i18n.receipt.open
        ? config.i18n.receipt.open
        : item.verifyUrl;
      block.append(link);
    }

    return block;
  };

  // Shows the success flash the server-side booth sets on cast, in the
  // layout's flash container (created when the page rendered without one).
  const showCastFlash = () => {
    const template = root.querySelector("template[data-booth-cast-flash]");
    const main = document.querySelector("main");
    if (!template || !main) {
      return;
    }
    let container = document.getElementById("flash-messages-container");
    if (!container) {
      container = document.createElement("div");
      container.id = "flash-messages-container";
      container.className = "container";
      main.before(container);
    }
    container.append(template.content.cloneNode(true));
  };

  const showReceipt = (receipts, { cast = false } = {}) => {
    const list = receipt.querySelector("[data-booth-receipts]");
    list.innerHTML = "";
    (receipts || []).forEach((item) => list.append(buildReceiptItem(item)));
    progress("");
    if (cast) {
      showCastFlash();
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
    show(activeQuestions[index]);
  };

  /**
   * Attaches next/back navigation listeners to a question section list.
   *
   * @param {HTMLElement[]} qList - question sections to wire up.
   * @returns {void}
   */
  const addNavigationListeners = (qList) => {
    qList.forEach((section, index) => {
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
        back.addEventListener("click", () => showQuestion(index - 1));
      }
      section.querySelector("[data-booth-next]").addEventListener("click", () => {
        if (!withinLimit(section)) {
          progress(i18n.max_choices_alert);
          return;
        }
        progress("");
        showQuestion(index + 1);
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

      if (alreadyRecordedBanner) {
        alreadyRecordedBanner.hidden = false;
      }
    }

    progress("");
    showQuestion(0);
  } catch (error) {
    fail(error.message);
  }
};

const start = () => document.querySelectorAll("[data-voting-booth]").forEach((root) => initBooth(root));

document.addEventListener("turbo:load", start);
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
