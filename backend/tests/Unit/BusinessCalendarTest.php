<?php

namespace Tests\Unit;

use App\Services\BusinessCalendar;
use Carbon\CarbonImmutable;
use PHPUnit\Framework\TestCase;

class BusinessCalendarTest extends TestCase
{
    private function calendar(array $holidays = [], string $tz = 'UTC'): BusinessCalendar
    {
        $d = [['09:00', '17:00']];

        return new BusinessCalendar(['mon' => $d, 'tue' => $d, 'wed' => $d, 'thu' => $d, 'fri' => $d], $tz, $holidays);
    }

    public function test_24x7_adds_wall_clock_minutes(): void
    {
        $c = new BusinessCalendar(null);
        $start = CarbonImmutable::parse('2026-10-10 23:30:00', 'UTC');
        $this->assertSame('2026-10-11 00:30:00', $c->addMinutes($start, 60)->format('Y-m-d H:i:s'));
        $this->assertSame(60, $c->minutesBetween($start, $start->addHour()));
    }

    public function test_rolls_over_to_next_business_day(): void
    {
        // Friday 16:00 + 2h => Monday 10:00
        $start = CarbonImmutable::parse('2026-10-09 16:00:00', 'UTC');
        $this->assertSame('2026-10-12 10:00:00', $this->calendar()->addMinutes($start, 120)->format('Y-m-d H:i:s'));
    }

    public function test_starts_counting_at_opening_time(): void
    {
        $start = CarbonImmutable::parse('2026-10-12 06:00:00', 'UTC'); // Monday before opening
        $this->assertSame('2026-10-12 09:30:00', $this->calendar()->addMinutes($start, 30)->format('Y-m-d H:i:s'));
    }

    public function test_skips_holidays(): void
    {
        $start = CarbonImmutable::parse('2026-10-09 16:00:00', 'UTC');
        $this->assertSame('2026-10-13 10:00:00', $this->calendar(['2026-10-12'])->addMinutes($start, 120)->format('Y-m-d H:i:s'));
    }

    public function test_minutes_between_counts_only_business_time(): void
    {
        $from = CarbonImmutable::parse('2026-10-09 16:00:00', 'UTC');
        $to = CarbonImmutable::parse('2026-10-12 10:00:00', 'UTC');
        $this->assertSame(120, $this->calendar()->minutesBetween($from, $to));
    }

    public function test_respects_policy_timezone(): void
    {
        // 09:00-17:00 in Karachi (UTC+5) => 04:00-12:00 UTC.
        $start = CarbonImmutable::parse('2026-10-12 03:00:00', 'UTC');
        $due = $this->calendar([], 'Asia/Karachi')->addMinutes($start, 60);
        $this->assertSame('2026-10-12 05:00:00', $due->format('Y-m-d H:i:s'));
        $this->assertSame('UTC', $due->getTimezone()->getName());
    }
}
