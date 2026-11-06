import { findVotingBackend } from "src/decidim/elections/voting_backends";

/**
 * Client-side booth stepper. Shows one question at a time, then the confirm
 * step, then the receipt. Answers never leave the page except through the
 * voting backend's adapter.
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
  const status = root.querySelector("[data-booth-status]");
  const steps = Array.from(root.querySelectorAll("[data-booth-step]"));
  const questions = Array.from(root.querySelectorAll("[data-booth-question]"));
  const preBallot = root.querySelector("[data-booth-step='pre-ballot']");
  const confirm = root.querySelector("[data-booth-step='confirm']");
  const receipt = root.querySelector("[data-booth-step='receipt']");
  const errorStep = root.querySelector("[data-booth-step='error']");

  const show = (section) => {
    steps.forEach((step) => {
      step.hidden = step !== section;
    });
    const heading = section.querySelector("[tabindex='-1']");
    if (heading) {
      heading.focus();
    }
  };

  const progress = (message) => {
    status.textContent = message || "";
  };

  const fail = (message) => {
    progress("");
    errorStep.querySelector("[data-booth-error-message]").textContent = message;
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

  const showReceipt = (receipts) => {
    const list = receipt.querySelector("[data-booth-receipts]");
    list.innerHTML = "";
    (receipts || []).forEach((item) => {
      const section = questions.find((question) => question.dataset.questionId === String(item.questionId));
      const li = document.createElement("li");
      li.className = "rounded-lg border border-gray p-4";
      const title = document.createElement("p");
      title.className = "font-semibold mb-2";
      title.textContent = section
        ? section.dataset.questionTitle
        : String(item.questionId);
      const code = document.createElement("code");
      code.className = "block break-all";
      code.textContent = item.code;
      li.append(title, code);
      if (item.verifyUrl) {
        const link = document.createElement("a");
        link.href = item.verifyUrl;
        link.target = "_blank";
        link.rel = "noopener";
        link.className = "button button__sm button__text-secondary mt-2";
        link.textContent = config.i18n && config.i18n.receipt
          ? config.i18n.receipt.open
          : item.verifyUrl;
        li.append(link);
      }
      list.append(li);
    });
    progress("");
    show(receipt);
  };

  const showConfirm = () => {
    const list = confirm.querySelector("[data-booth-confirm-list]");
    list.innerHTML = "";
    questions.forEach((section) => {
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
    if (index >= questions.length) {
      showConfirm();
      return;
    }
    show(questions[index]);
  };

  questions.forEach((section, index) => {
    const container = section.querySelector(".response[data-max-choices]");
    const alert = section.querySelector(".max-choices-alert");
    section.querySelectorAll("input[type=checkbox]").forEach((checkbox) => {
      checkbox.addEventListener("change", () => {
        if (container && alert) {
          alert.style.display = withinLimit(section)
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
    const ballot = questions.map((section) => ({
      questionId: section.dataset.questionId,
      responseOptionIds: selected(section)
    }));
    try {
      const result = await adapter.cast(ctx, ballot);
      showReceipt(result.receipts);
    } catch (error) {
      castButton.disabled = false;
      fail(error.message);
    }
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
