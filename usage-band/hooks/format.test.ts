import { expect, test } from 'claude-code/testing'

import {
  BLUE,
  GREEN,
  ORANGE,
  RED,
  contextText,
  effortLevel,
  effortMark,
  modelName,
  parseUsage,
  usageColor,
  usageParts,
} from './format'

test('a subscription reads its weekly window', () => {
  const parts = usageParts([
    { kind: 'five_hour', percentUsed: 23 },
    { kind: 'seven_day', percentUsed: 11.4 },
  ])
  expect(parts.map(p => p.text)).toEqual(['11%'])
})

test('an enterprise reads its monthly spend limit', () => {
  expect(usageParts([{ kind: 'spend_limit', percentUsed: 12 }]).map(p => p.text)).toEqual(['12%'])
  expect(usageParts([])).toEqual([])
})

test('monthly credits fill in only when no limit is reported', () => {
  expect(usageParts([], 54.4).map(p => p.text)).toEqual(['54%'])
  expect(usageParts([{ kind: 'seven_day', percentUsed: 11 }], 54).map(p => p.text)).toEqual(['11%'])
  expect(usageParts([{ kind: 'spend_limit', percentUsed: 12 }], 54).map(p => p.text)).toEqual([
    '12%',
  ])
})

test('the usage API answer reads the weekly window and the monthly credits', () => {
  expect(parseUsage('{"seven_day":{"utilization":22},"extra_usage":null}')).toEqual({
    weekly: 22,
    monthly: undefined,
  })
  expect(
    parseUsage(
      '{"seven_day":null,"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250,"utilization":24}}',
    ),
  ).toEqual({ weekly: undefined, monthly: 25 })
  expect(
    parseUsage(
      '{"seven_day":null,"spend":{"percent":37.6,"used":{"amount_minor":37600,"exponent":2,"currency":"USD"}},"extra_usage":{"is_enabled":false,"utilization":5}}',
    ),
  ).toEqual({ weekly: undefined, monthly: 37.6 })
  expect(parseUsage('{"extra_usage":{"is_enabled":false,"utilization":54.4}}')).toEqual({
    weekly: undefined,
    monthly: 54.4,
  })
  expect(parseUsage('{"five_hour":{"utilization":3}}')).toEqual({
    weekly: undefined,
    monthly: undefined,
  })
  expect(parseUsage('not json')).toEqual({})
})

test('usage colours change at 80 and 90', () => {
  expect(usageColor(79.9)).toBe(GREEN)
  expect(usageColor(80)).toBe(ORANGE)
  expect(usageColor(90)).toBe(RED)
})

test('context reads in k and m', () => {
  expect(contextText(45_500, 1_000_000, 4.55)).toBe('Context 45.5k/1m (5%)')
  expect(contextText(12_000, 200_000, 6)).toBe('Context 12k/200k (6%)')
})

test('effort levels read as marks', () => {
  expect(effortMark('low')).toEqual({ mark: '🡓', color: BLUE })
  expect(effortMark('medium')).toEqual({ mark: '-', color: GREEN })
  expect(effortMark('high')).toEqual({ mark: '🡑', color: ORANGE })
  expect(effortMark('xhigh')).toEqual({ mark: '🡑', color: RED })
  expect(effortMark('max')).toEqual({ mark: '🡑', color: RED })
  expect(effortMark(null)).toBe(null)
})

test('the saved effort is the model\'s own, else the global one', () => {
  const settings = {
    effortLevel: 'medium',
    modelSettings: { 'claude-sonnet-5-5': { effortLevel: 'low' } },
  }
  expect(effortLevel(settings, 'claude-sonnet-5-5[1m]')).toBe('low')
  expect(effortLevel(settings, 'claude-opus-5-5')).toBe('medium')
  expect(effortLevel({}, 'claude-opus-5-5')).toBe(null)
})

test('model ids read as their display names', () => {
  expect(modelName('claude-sonnet-5-5')).toBe('Sonnet 5.5')
  expect(modelName('claude-opus-5-5[1m]')).toBe('Opus 5.5')
  expect(modelName('claude-opus-4-1-20250805')).toBe('Opus 4.1')
  expect(modelName('claude-sonnet-4-20250514')).toBe('Sonnet 4')
  expect(modelName('Sonnet 5.5')).toBe('Sonnet 5.5')
})
