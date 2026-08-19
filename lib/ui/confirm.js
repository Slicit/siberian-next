// Turbo's confirmation is window.confirm, which is a grey box from the browser
// chrome with an OK button. It says nothing about whether the thing about to
// happen is reversible, and it looks identical whether you are renaming a
// domain or destroying one.
//
// This replaces it with a dialog in the page: the same text Turbo was given,
// and a confirm button that turns red when the control that asked was
// destructive, so the colour of the answer matches the colour of the question.
import { Turbo } from "@hotwired/turbo-rails";

const dialog = document.createElement("dialog");
dialog.className = "confirm";
dialog.innerHTML = `
  <form method="dialog">
    <div class="body">
      <h2 data-title>Are you sure?</h2>
      <p data-message></p>
    </div>
    <div class="actions">
      <button value="cancel" data-cancel>Cancel</button>
      <button value="confirm" class="primary" data-confirm>Continue</button>
    </div>
  </form>
`;

function ready() {
  if (!dialog.isConnected) document.body.appendChild(dialog);
  return dialog;
}

// A destructive control is one already marked as such. Nothing here guesses
// from the wording: a button that says "Remove" and is not styled danger is a
// button somebody meant to be ordinary.
function destructive(element, submitter) {
  const source = submitter || element;
  return Boolean(source?.closest?.(".danger") || source?.classList?.contains("danger") ||
                 element?.querySelector?.(".danger"));
}

Turbo.setConfirmMethod((message, element, submitter) => {
  const node = ready();
  const confirm = node.querySelector("[data-confirm]");

  node.querySelector("[data-message]").textContent = message;
  const danger = destructive(element, submitter);
  confirm.textContent = danger ? "Yes, do it" : "Continue";
  confirm.className = danger ? "danger" : "primary";
  node.querySelector("[data-title]").textContent = danger ? "This cannot be undone" : "Are you sure?";

  return new Promise((resolve) => {
    node.addEventListener("close", () => resolve(node.returnValue === "confirm"), { once: true });
    node.showModal();
    // Cancel takes the focus, so a stray Enter does nothing rather than the
    // thing being asked about.
    node.querySelector("[data-cancel]").focus();
  });
});
