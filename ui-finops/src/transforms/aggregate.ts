import type { CloudCostItem, CloudCostSet } from "../types/cloudCost";
import type { Money } from "../types/viewModels";

function itemMoney(item: CloudCostItem): Money {
  return {
    list: item.listCost?.cost ?? 0,
    net: item.netCost?.cost ?? 0,
  };
}

function addMoney(a: Money, b: Money): Money {
  return { list: a.list + b.list, net: a.net + b.net };
}

export function sumSets(sets: CloudCostSet[]): Money {
  let total: Money = { list: 0, net: 0 };
  for (const set of sets) {
    for (const item of Object.values(set.cloudCosts ?? {})) {
      total = addMoney(total, itemMoney(item));
    }
  }
  return total;
}

export function sumByKey(
  sets: CloudCostSet[],
  keyFn: (name: string, item: CloudCostItem) => string,
): Map<string, Money> {
  const totals = new Map<string, Money>();
  for (const set of sets) {
    for (const [name, item] of Object.entries(set.cloudCosts ?? {})) {
      const key = keyFn(name, item);
      const current = totals.get(key) ?? { list: 0, net: 0 };
      totals.set(key, addMoney(current, itemMoney(item)));
    }
  }
  return totals;
}
