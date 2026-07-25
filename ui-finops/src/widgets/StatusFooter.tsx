import type { CloudCostStatusRow } from "../types/cloudCost";
import type { ResolvedWindow } from "../transforms/windows";

type StatusFooterProps = {
  currentWindow: ResolvedWindow;
  priorWindow: ResolvedWindow;
  statusRow: CloudCostStatusRow | null;
};

export function StatusFooter({
  currentWindow,
  priorWindow,
  statusRow,
}: StatusFooterProps) {
  return (
    <footer className="status-footer" aria-label="Cloud cost status">
      <div>
        <span className="footer-label">Connection</span>
        <strong>{statusRow?.connectionStatus ?? "Unknown"}</strong>
      </div>
      <div>
        <span className="footer-label">Current window</span>
        <strong>{currentWindow.label}</strong>
        <code>{currentWindow.window}</code>
      </div>
      <div>
        <span className="footer-label">Comparison</span>
        <strong>{priorWindow.label}</strong>
        <code>{priorWindow.window}</code>
      </div>
      <div>
        <span className="footer-label">Last run</span>
        <strong>{statusRow?.lastRun ?? "Unavailable"}</strong>
      </div>
      <div>
        <span className="footer-label">Next run</span>
        <strong>{statusRow?.nextRun ?? "Unavailable"}</strong>
      </div>
    </footer>
  );
}
