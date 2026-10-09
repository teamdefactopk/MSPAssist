<?php

namespace App\Services;

use App\Models\SlaPolicy;
use Carbon\CarbonImmutable;
use Carbon\CarbonInterface;

/**
 * Business-time arithmetic for SLA calculations.
 *
 * Business hours are expressed per weekday in the policy timezone, e.g.
 * {"mon": [["09:00","17:00"]], "tue": [["09:00","12:00"],["13:00","17:00"]]}.
 * A null schedule means the clock runs 24x7. Holidays are Y-m-d dates in the
 * policy timezone. All inputs/outputs are converted back to UTC.
 */
class BusinessCalendar
{
    private const DAY_KEYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

    /** Safety bound so a malformed schedule can never loop forever (~10 years). */
    private const MAX_DAYS = 3660;

    /**
     * @param  array<string, list<array{0:string,1:string}>>|null  $hours
     * @param  list<string>  $holidays
     */
    public function __construct(
        private readonly ?array $hours,
        private readonly string $timezone = 'UTC',
        private readonly array $holidays = [],
    ) {}

    public static function forPolicy(?SlaPolicy $policy): self
    {
        if (! $policy) {
            return new self(null);
        }

        return new self($policy->business_hours ?: null, $policy->timezone ?: 'UTC', $policy->holidays ?? []);
    }

    public function is24x7(): bool
    {
        if ($this->hours === null) {
            return true;
        }
        foreach ($this->hours as $intervals) {
            if (! empty($intervals)) {
                return false;
            }
        }

        // An empty schedule would never accrue time; treat it as 24x7.
        return true;
    }

    public function addMinutes(CarbonInterface $start, int $minutes): CarbonImmutable
    {
        $start = CarbonImmutable::instance($start);
        if ($minutes <= 0) {
            return $start->utc();
        }
        if ($this->is24x7()) {
            return $start->addMinutes($minutes)->utc();
        }

        $cursor = $start->setTimezone($this->timezone);
        $remaining = $minutes;
        for ($i = 0; $i < self::MAX_DAYS; $i++) {
            foreach ($this->intervalsFor($cursor) as [$from, $to]) {
                if ($cursor->gte($to)) {
                    continue;
                }
                $begin = $cursor->gt($from) ? $cursor : $from;
                $available = (int) floor($begin->diffInSeconds($to) / 60);
                if ($remaining <= $available) {
                    return $begin->addMinutes($remaining)->utc();
                }
                $remaining -= $available;
            }
            $cursor = $cursor->addDay()->startOfDay();
        }

        return $start->addMinutes($minutes)->utc();
    }

    public function minutesBetween(CarbonInterface $from, CarbonInterface $to): int
    {
        $from = CarbonImmutable::instance($from);
        $to = CarbonImmutable::instance($to);
        if ($to->lte($from)) {
            return 0;
        }
        if ($this->is24x7()) {
            return (int) floor($from->diffInSeconds($to) / 60);
        }

        $cursor = $from->setTimezone($this->timezone);
        $end = $to->setTimezone($this->timezone);
        $seconds = 0;
        for ($i = 0; $i < self::MAX_DAYS && $cursor->lt($end); $i++) {
            foreach ($this->intervalsFor($cursor) as [$a, $b]) {
                $s = $cursor->gt($a) ? $cursor : $a;
                $e = $end->lt($b) ? $end : $b;
                if ($e->gt($s)) {
                    $seconds += $s->diffInSeconds($e);
                }
            }
            $cursor = $cursor->addDay()->startOfDay();
        }

        return (int) floor($seconds / 60);
    }

    /** @return list<array{0:CarbonImmutable,1:CarbonImmutable}> */
    private function intervalsFor(CarbonImmutable $day): array
    {
        if (in_array($day->format('Y-m-d'), $this->holidays, true)) {
            return [];
        }
        $key = self::DAY_KEYS[$day->dayOfWeek];
        $result = [];
        foreach ($this->hours[$key] ?? [] as $interval) {
            [$open, $close] = $interval;
            $a = $day->setTimeFromTimeString($open);
            $b = $close === '24:00' ? $day->addDay()->startOfDay() : $day->setTimeFromTimeString($close);
            if ($b->gt($a)) {
                $result[] = [$a, $b];
            }
        }
        usort($result, fn ($x, $y) => $x[0] <=> $y[0]);

        return $result;
    }
}
