/**
 * Receipt extras of the client-side booth: the waiting panel shown while the
 * next per-question question is still closed, and the "already recorded"
 * banner shown when a partial ballot is resumed.
 *
 * @param {Object} options - booth elements and helpers.
 * @param {HTMLElement} options.receipt - the receipt step.
 * @param {HTMLElement|null} options.banner - the `[data-booth-already-recorded]` announcement.
 * @param {Function} options.progress - sets the booth status line.
 * @param {Object} options.i18n - booth texts.
 * @returns {Object} controls used by `booth.js`.
 */
export const createReceiptPanels = ({ receipt, banner, progress, i18n }) => {
  const panel = receipt && receipt.querySelector("[data-booth-waiting]");
  const header = receipt && receipt.querySelector("[data-booth-receipt-header]");

  const toggle = (on) => {
    if (panel) {
      panel.hidden = !on;
    }
    if (header) {
      header.hidden = on;
    }
  };

  // The banner's announcement is rendered by the server; only its visibility changes.
  const setBanner = (on) => {
    if (banner) {
      banner.hidden = !on;
    }
  };
  const hideBanner = () => setBanner(false);
  const showBanner = () => setBanner(true);

  // Adapter hook: the panel on the receipt step, the status line on any other step.
  const waiting = (on) => {
    if (!panel) {
      return;
    }
    if (receipt.hidden) {
      progress(on && i18n.waiting
        ? i18n.waiting.title
        : "");
      return;
    }
    toggle(on);
    if (on) {
      progress("");
    }
  };

  // Leaving the receipt step hides the panel and restores the success header.
  const leave = () => toggle(false);

  return { waiting, leave, showBanner, hideBanner };
};

/**
 * Builds the receipt block of one question, laid out like the confirm step's
 * answer list: question title, compact receipt code and verify link.
 *
 * @param {HTMLElement[]} questions - the booth's question sections.
 * @param {Object} config - booth config (`config.i18n.receipt.open` labels the link).
 * @returns {Function} `(item) => HTMLElement` for a `{ questionId, code, verifyUrl }` receipt.
 */
export const createReceiptItemBuilder = (questions, config) => (item) => {
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

/**
 * Shows the success flash the server-side booth sets on cast, in the layout's
 * flash container (created when the page rendered without one). A later cast
 * on the same page replaces it, so it is shown once.
 *
 * @param {HTMLElement} root - the `[data-voting-booth]` element.
 * @returns {void}
 */
export const showCastFlash = (root) => {
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
  const flash = template.content.firstElementChild.cloneNode(true);
  flash.dataset.boothCastFlash = "";
  container.querySelectorAll("[data-booth-cast-flash]").forEach((old) => old.remove());
  container.append(flash);
};
