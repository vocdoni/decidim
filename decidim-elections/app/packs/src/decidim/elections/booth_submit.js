import { findVotingBackend } from "src/decidim/elections/voting_backends";

/**
 * Builds the per-question submit status screen shown after a partial-failure cast.
 *
 * @param {Object} opts - booth dependencies.
 * @param {HTMLElement[]} opts.questions - all question DOM elements.
 * @param {HTMLElement} opts.submitStep - the `[data-booth-step="submit"]` element.
 * @param {Function} opts.progress - progress status updater.
 * @param {Function} opts.show - step display function.
 * @param {Function} opts.showReceipt - receipt display function.
 * @param {Function} opts.buildReceiptItem - builds a confirmed receipt `<li>`.
 * @param {Function} opts.selected - returns checked input values for a section.
 * @param {Object} opts.i18n - booth i18n strings.
 * @param {Object} opts.ctx - voting backend context.
 * @param {string} opts.backendName - adapter name passed to `findVotingBackend`.
 * @returns {Function} `showSubmit({ confirmed, unconfirmed, failed })`.
 */
export const createSubmitStep = ({ questions, submitStep, progress, show, showReceipt, buildReceiptItem, selected, i18n, ctx, backendName }) => {
  const sub = i18n.submit || {};

  const questionTitle = (item) => {
    const sect = questions.find((el) => el.dataset.questionId === String(item.questionId));

    return sect
      ? sect.dataset.questionTitle
      : String(item.questionId);
  };

  const makeStatusRow = ({ cls, badge, text, error = null }) => {
    const li = document.createElement("li");
    li.className = `rounded-lg border border-${cls} p-4`;
    const badgeEl = document.createElement("span");
    badgeEl.className = `text-${cls} text-sm font-semibold`;
    badgeEl.textContent = badge;
    const titleEl = document.createElement("p");
    titleEl.className = "font-semibold mb-1";
    titleEl.textContent = text;
    li.append(badgeEl, titleEl);
    if (error) {
      const errEl = document.createElement("p");
      errEl.className = "text-sm mt-1";
      errEl.textContent = error;
      li.append(errEl);
    }

    return li;
  };

  /**
   * Shows the partial-failure submit screen. Called when at least one question
   * was unconfirmed or definitively failed.
   *
   * @param {{confirmed: Array, unconfirmed: Array, failed: Array}} result - cast outcome.
   * @returns {void}
   */
  const showSubmit = ({ confirmed, unconfirmed, failed }) => {
    const list = submitStep.querySelector("[data-booth-submit-list]");
    const titleEl = submitStep.querySelector("[data-booth-submit-title]");
    const summaryEl = submitStep.querySelector("[data-booth-submit-summary]");
    const retryBtn = submitStep.querySelector("[data-booth-retry]");
    const recheckBtn = submitStep.querySelector("[data-booth-recheck]");

    list.innerHTML = "";
    titleEl.textContent = sub.title || "";
    retryBtn.hidden = true;
    recheckBtn.hidden = true;

    confirmed.forEach((item) => {
      const li = buildReceiptItem(item);
      li.classList.add("border-success");
      const badge = document.createElement("span");
      badge.className = "text-success text-sm font-semibold";
      badge.textContent = sub.done || "";
      li.prepend(badge);
      list.append(li);
    });
    unconfirmed.forEach((item) => list.append(makeStatusRow({ cls: "warning", badge: sub.unconfirmed || "", text: questionTitle(item) })));
    failed.forEach((item) => list.append(makeStatusRow({ cls: "alert", badge: sub.failed || "", text: questionTitle(item), error: item.error })));

    if (failed.length > 0) {
      summaryEl.textContent = sub.summary_failed || "";
      retryBtn.hidden = false;
    } else if (unconfirmed.length > 0) {
      summaryEl.textContent = sub.summary_unconfirmed || "";
      recheckBtn.hidden = false;
    }
    progress("");
    show(submitStep);

    retryBtn.addEventListener("click", async () => {
      retryBtn.disabled = true;
      progress(i18n.casting || "");
      const retryBallot = failed.map((item) => {
        const sect = questions.find((el) => el.dataset.questionId === String(item.questionId));

        return {
          questionId: item.questionId,
          responseOptionIds: sect
            ? selected(sect)
            : []
        };
      });
      let retryAdapter = null;
      try {
        retryAdapter = await findVotingBackend(backendName);
      } catch {
        retryBtn.disabled = false;
        return;
      }
      const retryResult = await retryAdapter.cast(ctx, retryBallot);
      const nextConfirmed = [...confirmed, ...retryResult.receipts];
      if (retryResult.unconfirmed.length === 0 && retryResult.failed.length === 0) {
        showReceipt(nextConfirmed);
      } else {
        showSubmit({ confirmed: nextConfirmed, unconfirmed: retryResult.unconfirmed, failed: retryResult.failed });
      }
    });

    recheckBtn.addEventListener("click", async () => {
      recheckBtn.disabled = true;
      progress(sub.rechecking || "");
      let recheckAdapter = null;
      try {
        recheckAdapter = await findVotingBackend(backendName);
      } catch {
        recheckBtn.disabled = false;
        progress("");
        return;
      }
      const recheckResult = await recheckAdapter.recheck(ctx);
      const recheckIds = new Set(recheckResult.receipts.map((rec) => String(rec.questionId)));
      const nowConfirmed = [...confirmed, ...recheckResult.receipts];
      const stillUnconfirmed = unconfirmed.filter((item) => !recheckIds.has(String(item.questionId)));
      if (stillUnconfirmed.length === 0 && failed.length === 0) {
        showReceipt(nowConfirmed);
      } else {
        showSubmit({ confirmed: nowConfirmed, unconfirmed: stillUnconfirmed, failed });
      }
    });
  };

  return showSubmit;
};
