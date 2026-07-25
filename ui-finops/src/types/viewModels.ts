export type Money = { list: number; net: number };

export type WindowPreset = "7d" | "30d" | "mtd" | "invoice";

export type ServiceCost = {
  service: string;
  money: Money;
  bucketId: string;
  gmpSubId?: string;
};

export type BucketCost = {
  bucketId: string;
  label: string;
  money: Money;
};

export type MoverRow = {
  key: string;
  current: Money;
  prior: Money;
  deltaList: number;
  deltaNet: number;
  pctList: number | null;
  pctNet: number | null;
};
