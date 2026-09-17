package com.local.crashmonitor;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) return;

        boolean enabled = context.getSharedPreferences(MonitoringService.PREFS, Context.MODE_PRIVATE)
                .getBoolean(MonitoringService.PREF_MASTER, true);
        if (!enabled) return;

        Intent service = new Intent(context, MonitoringService.class);
        service.setAction(MonitoringService.ACTION_START);
        try {
            context.startForegroundService(service);
        } catch (Throwable ignored) { }
    }
}
