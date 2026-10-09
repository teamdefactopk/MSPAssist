<?php

namespace App\Enums;

enum Role: string
{
    case Admin = 'admin';
    case SupportManager = 'support_manager';
    case Technician = 'technician';
    case ClientAdmin = 'client_admin';
    case ClientUser = 'client_user';

    public function label(): string
    {
        return match ($this) {
            self::Admin => 'CyberCraft Administrator',
            self::SupportManager => 'Support Manager',
            self::Technician => 'Technician',
            self::ClientAdmin => 'Client Administrator',
            self::ClientUser => 'Client User',
        };
    }

    public function isStaff(): bool
    {
        return in_array($this, [self::Admin, self::SupportManager, self::Technician], true);
    }

    public function isClient(): bool
    {
        return ! $this->isStaff();
    }

    /** Staff roles that may manage (assign, re-prioritise, configure) any ticket. */
    public function isManager(): bool
    {
        return in_array($this, [self::Admin, self::SupportManager], true);
    }

    /** @return list<Role> roles this role may invite or assign. */
    public function assignableRoles(): array
    {
        return match ($this) {
            self::Admin => self::cases(),
            self::SupportManager => [self::Technician, self::ClientAdmin, self::ClientUser],
            self::ClientAdmin => [self::ClientAdmin, self::ClientUser],
            default => [],
        };
    }
}
