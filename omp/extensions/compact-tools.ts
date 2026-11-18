import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

// Claude desktop style transcript: every tool call draws as one compact row; its toggle opens the full card.
// Needs omp's `extensionRenderers.transcriptPresenters` setting on.
export default function compactTools(pi: ExtensionAPI) {
	pi.registerTranscriptPresenter(block => (block.type === "toolCall" ? "compact" : undefined));
}
