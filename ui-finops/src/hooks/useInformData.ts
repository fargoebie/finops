import { useCallback, useEffect, useMemo, useState } from "react";
import { fetchCloudCost, fetchStatus } from "../api/cloudCost";
import type {
  CloudCostResponse,
  CloudCostStatusResponse,
  CloudCostStatusRow,
} from "../types/cloudCost";
import type { Money, WindowPreset } from "../types/viewModels";
import {
  priorWindow,
  resolveWindow,
  type ResolvedWindow,
} from "../transforms/windows";
import { sumSets } from "../transforms/aggregate";

type FetchCloudCost = (
  window: string,
  aggregate: string,
) => Promise<CloudCostResponse>;

export type ExecPulseTotals = {
  mtd: Money;
  priorSevenDay: Money;
  rollingSevenDay: Money;
  rollingThirtyDay: Money;
  wow: {
    list: number | null;
    net: number | null;
  };
};

export type ExecPulseState = {
  data: ExecPulseTotals | null;
  error: string | null;
  loading: boolean;
  retry: () => void;
};

export type InformData = {
  connectionStatus: string | undefined;
  currentWindow: ResolvedWindow;
  execPulse: ExecPulseState;
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

export function percentChange(current: number, prior: number): number | null {
  if (prior === 0) {
    return null;
  }

  return ((current - prior) / prior) * 100;
}

export async function fetchExecPulseTotals(
  now: Date,
  invoiceMonth: string,
  fetcher: FetchCloudCost = fetchCloudCost,
): Promise<ExecPulseTotals> {
  const mtdWindow = resolveWindow("mtd", now, invoiceMonth);
  const rollingSevenDayWindow = resolveWindow("7d", now, invoiceMonth);
  const rollingThirtyDayWindow = resolveWindow("30d", now, invoiceMonth);
  const priorSevenDayWindow = priorWindow("7d", now, invoiceMonth);

  const [mtd, rollingSevenDay, rollingThirtyDay, priorSevenDay] =
    await Promise.all([
      fetcher(mtdWindow.window, "provider"),
      fetcher(rollingSevenDayWindow.window, "provider"),
      fetcher(rollingThirtyDayWindow.window, "provider"),
      fetcher(priorSevenDayWindow.window, "provider"),
    ]);

  const mtdTotal = sumSets(mtd.data.sets);
  const rollingSevenDayTotal = sumSets(rollingSevenDay.data.sets);
  const rollingThirtyDayTotal = sumSets(rollingThirtyDay.data.sets);
  const priorSevenDayTotal = sumSets(priorSevenDay.data.sets);

  return {
    mtd: mtdTotal,
    priorSevenDay: priorSevenDayTotal,
    rollingSevenDay: rollingSevenDayTotal,
    rollingThirtyDay: rollingThirtyDayTotal,
    wow: {
      list: percentChange(rollingSevenDayTotal.list, priorSevenDayTotal.list),
      net: percentChange(rollingSevenDayTotal.net, priorSevenDayTotal.net),
    },
  };
}

export function useInformData({
  invoiceMonth,
  preset,
}: UseInformDataOptions): InformData {
  const now = useMemo(() => new Date(), [invoiceMonth]);
  const [status, setStatus] = useState<CloudCostStatusResponse | null>(null);
  const [statusError, setStatusError] = useState<string | null>(null);
  const [statusLoading, setStatusLoading] = useState(true);
  const [execPulseData, setExecPulseData] = useState<ExecPulseTotals | null>(null);
  const [execPulseError, setExecPulseError] = useState<string | null>(null);
  const [execPulseLoading, setExecPulseLoading] = useState(true);
  const [execPulseRefresh, setExecPulseRefresh] = useState(0);

  const retryExecPulse = useCallback(() => {
    setExecPulseRefresh((refresh) => refresh + 1);
  }, []);

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

  useEffect(() => {
    let active = true;

    setExecPulseLoading(true);
    setExecPulseError(null);

    fetchExecPulseTotals(now, invoiceMonth)
      .then((data) => {
        if (active) {
          setExecPulseData(data);
        }
      })
      .catch((error: unknown) => {
        if (active) {
          setExecPulseError(error instanceof Error ? error.message : String(error));
          setExecPulseData(null);
        }
      })
      .finally(() => {
        if (active) {
          setExecPulseLoading(false);
        }
      });

    return () => {
      active = false;
    };
  }, [execPulseRefresh, invoiceMonth, now]);

  const statusRow = status?.data[0] ?? null;

  return {
    connectionStatus: statusRow?.connectionStatus,
    currentWindow: resolveWindow(preset, now, invoiceMonth),
    execPulse: {
      data: execPulseData,
      error: execPulseError,
      loading: execPulseLoading,
      retry: retryExecPulse,
    },
    priorWindow: priorWindow(preset, now, invoiceMonth),
    status,
    statusError,
    statusLoading,
    statusRow,
  };
}
