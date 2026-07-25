import { useEffect, useMemo, useState } from "react";
import { fetchStatus } from "../api/cloudCost";
import type {
  CloudCostStatusResponse,
  CloudCostStatusRow,
} from "../types/cloudCost";
import type { WindowPreset } from "../types/viewModels";
import {
  priorWindow,
  resolveWindow,
  type ResolvedWindow,
} from "../transforms/windows";

export type InformData = {
  connectionStatus: string | undefined;
  currentWindow: ResolvedWindow;
  priorWindow: ResolvedWindow;
  status: CloudCostStatusResponse | null;
  statusError: string | null;
  statusLoading: boolean;
  statusRow: CloudCostStatusRow | null;
};

type UseInformDataOptions = {
  invoiceMonth: string;
  preset: WindowPreset;
};

export function useInformData({
  invoiceMonth,
  preset,
}: UseInformDataOptions): InformData {
  const now = useMemo(() => new Date(), [invoiceMonth, preset]);
  const [status, setStatus] = useState<CloudCostStatusResponse | null>(null);
  const [statusError, setStatusError] = useState<string | null>(null);
  const [statusLoading, setStatusLoading] = useState(true);

  useEffect(() => {
    let active = true;

    setStatusLoading(true);
    setStatusError(null);

    fetchStatus()
      .then((response) => {
        if (active) {
          setStatus(response);
        }
      })
      .catch((error: unknown) => {
        if (active) {
          setStatusError(error instanceof Error ? error.message : String(error));
          setStatus(null);
        }
      })
      .finally(() => {
        if (active) {
          setStatusLoading(false);
        }
      });

    return () => {
      active = false;
    };
  }, []);

  const statusRow = status?.data[0] ?? null;

  return {
    connectionStatus: statusRow?.connectionStatus,
    currentWindow: resolveWindow(preset, now, invoiceMonth),
    priorWindow: priorWindow(preset, now, invoiceMonth),
    status,
    statusError,
    statusLoading,
    statusRow,
  };
}
