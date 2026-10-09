<?php

namespace App\Enums;

enum WorkLogType: string
{
    case Remote = 'remote';
    case Onsite = 'onsite';
    case Phone = 'phone';
    case Workshop = 'workshop';
}
