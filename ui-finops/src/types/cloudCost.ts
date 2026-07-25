export type CostMetric = { cost: number; kubernetesPercent?: number };

export type CloudCostItem = {
  properties?: {
    provider?: string;
    accountID?: string;
    service?: string;
    category?: string;
    regionID?: string;
  };
  listCost?: CostMetric;
  netCost?: CostMetric;
};

export type CloudCostSet = {
  cloudCosts?: Record<string, CloudCostItem>;
  window?: { start?: string; end?: string };
  aggregationProperties?: string[];
};

export type CloudCostResponse = {
  code: number;
  data: { sets: CloudCostSet[]; window?: { start?: string; end?: string } };
};

export type CloudCostStatusRow = {
  connectionStatus?: string;
  lastRun?: string;
  nextRun?: string;
  coverage?: string;
  provider?: string;
};

export type CloudCostStatusResponse = {
  code: number;
  data: CloudCostStatusRow[];
};

export type ViewGraphResponse = {
  code: number;
  data: Array<{
    start: string;
    end: string;
    items: Array<{ name: string; value: number }>;
  }>;
};
