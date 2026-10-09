<?php

namespace App\Services;

use Illuminate\Support\Facades\DB;

class TicketNumberGenerator
{
    /** Must be called inside a transaction. Produces e.g. CC-2026-000123. */
    public function next(): string
    {
        $year = (int) now()->format('Y');
        $row = DB::table('ticket_sequences')->where('year', $year)->lockForUpdate()->first();
        if (! $row) {
            DB::table('ticket_sequences')->insertOrIgnore(['year' => $year, 'last_number' => 0]);
            $row = DB::table('ticket_sequences')->where('year', $year)->lockForUpdate()->first();
        }
        $number = $row->last_number + 1;
        DB::table('ticket_sequences')->where('year', $year)->update(['last_number' => $number]);

        $prefix = config('mspassist.ticket_prefix', 'CC');

        return sprintf('%s-%d-%06d', $prefix, $year, $number);
    }
}
