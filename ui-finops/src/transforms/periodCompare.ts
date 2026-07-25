import type { Money, MoverRow } from "../types/viewModels";

const zeroMoney: Money = { list: 0, net: 0 };

function pctChange(delta: number, prior: number): number | null {
  if (prior === 0) {
    return null;
  }
  return (delta / prior) * 100;
}

export function periodCompare(
  current: Map<string, Money>,
  prior: Map<string, Money>,
): MoverRow[] {
  const keys = new Set([...current.keys(), ...prior.keys()]);
  const rows: MoverRow[] = [];

  for (const key of keys) {
    const currentMoney = current.get(key) ?? zeroMoney;
    const priorMoney = prior.get(key) ?? zeroMoney;
    const deltaList = currentMoney.list - priorMoney.list;
    const deltaNet = currentMoney.net - priorMoney.net;

    rows.push({
      key,
      current: currentMoney,
      prior: priorMoney,
      deltaList,
      deltaNet,
      pctList: pctChange(deltaList, priorMoney.list),
      pctNet: pctChange(deltaNet, priorMoney.net),
    });
  }

  return rows.sort((a, b) => Math.abs(b.deltaList) - Math.abs(a.deltaList));
}
