import categoryMap from "../../config/gcp-category-map.json";
import type { BucketCost, Money, ServiceCost } from "../types/viewModels";

type BucketDefinition = {
  id: string;
  label: string;
};

type GmpSubBucketDefinition = BucketDefinition & {
  services: string[];
};

type ServiceNamePattern = {
  pattern: string;
  bucket: string;
};

export type CategoryMap = {
  version: number;
  description?: string;
  buckets: BucketDefinition[];
  gmpSubBuckets: GmpSubBucketDefinition[];
  serviceToBucket: Record<string, string>;
  serviceNamePatterns: ServiceNamePattern[];
  defaults: {
    unmappedBucket: string;
    costBasis?: string;
    discountHighlightPct?: number;
    topN?: number;
  };
};

export function loadCategoryMap(): CategoryMap {
  return categoryMap as CategoryMap;
}

function addMoney(a: Money, b: Money): Money {
  return { list: a.list + b.list, net: a.net + b.net };
}

function gmpSubId(service: string, map: CategoryMap): string | undefined {
  return map.gmpSubBuckets.find((bucket) => bucket.services.includes(service))?.id;
}

function patternBucket(service: string, map: CategoryMap): string | undefined {
  return map.serviceNamePatterns.find(({ pattern }) => new RegExp(pattern).test(service))?.bucket;
}

function mappedBucket(service: string, map: CategoryMap): string | undefined {
  return map.serviceToBucket[service] ?? patternBucket(service, map);
}

export function resolveBucket(
  service: string,
  map: CategoryMap,
): { bucketId: string; gmpSubId?: string } {
  const bucketId = mappedBucket(service, map) ?? map.defaults.unmappedBucket;
  const subId = bucketId === "gmp" ? gmpSubId(service, map) : undefined;
  return subId ? { bucketId, gmpSubId: subId } : { bucketId };
}

export function bucketizeServices(
  byService: Map<string, Money>,
  map: CategoryMap,
): { buckets: BucketCost[]; services: ServiceCost[]; unmappedCount: number } {
  const services: ServiceCost[] = [];
  const totals = new Map<string, Money>();
  let unmappedCount = 0;

  for (const [service, money] of byService) {
    if (mappedBucket(service, map) === undefined) {
      unmappedCount += 1;
    }

    const resolved = resolveBucket(service, map);
    services.push({ service, money, ...resolved });
    totals.set(resolved.bucketId, addMoney(totals.get(resolved.bucketId) ?? { list: 0, net: 0 }, money));
  }

  const buckets = map.buckets
    .filter((bucket) => totals.has(bucket.id))
    .map((bucket) => ({
      bucketId: bucket.id,
      label: bucket.label,
      money: totals.get(bucket.id) ?? { list: 0, net: 0 },
    }));

  return { buckets, services, unmappedCount };
}

export function gmpSubMix(services: ServiceCost[], map: CategoryMap): BucketCost[] {
  const totals = new Map<string, Money>();

  for (const service of services) {
    if (service.bucketId !== "gmp") {
      continue;
    }

    const subId = service.gmpSubId ?? gmpSubId(service.service, map);
    if (subId === undefined) {
      continue;
    }

    totals.set(subId, addMoney(totals.get(subId) ?? { list: 0, net: 0 }, service.money));
  }

  return map.gmpSubBuckets
    .filter((bucket) => totals.has(bucket.id))
    .map((bucket) => ({
      bucketId: bucket.id,
      label: bucket.label,
      money: totals.get(bucket.id) ?? { list: 0, net: 0 },
    }));
}
