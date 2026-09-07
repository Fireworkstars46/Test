package com.example.heychatgptassist;

import android.content.pm.PackageManager;

import java.lang.reflect.Method;

import rikka.shizuku.Shizuku;

public final class ShizukuBridge {
    private ShizukuBridge() {}

    public static boolean isRunning() {
        try {
            return Shizuku.pingBinder();
        } catch (Throwable t) {
            return false;
        }
    }

    public static boolean hasPermission() {
        try {
            return isRunning() &&
                    Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED;
        } catch (Throwable t) {
            return false;
        }
    }

    public static String statusText() {
        if (!isRunning()) return "Shizuku is not running";
        if (!hasPermission()) return "Shizuku is running, permission not granted";
        try {
            return "Shizuku ready (UID " + Shizuku.getUid() + ")";
        } catch (Throwable t) {
            return "Shizuku ready";
        }
    }

    public static Result sendKeyEvent(int keyCode) {
        if (!isRunning()) {
            return new Result(false, "Shizuku is not running");
        }
        if (!hasPermission()) {
            return new Result(false, "Shizuku permission is not granted");
        }

        Object process = null;
        try {
            // API 13.1.5 still contains Shizuku.newProcess internally. It is private in
            // recent API 13 builds, so reflection is used here to run the tiny shell command.
            Method newProcess = Shizuku.class.getDeclaredMethod(
                    "newProcess", String[].class, String[].class, String.class);
            newProcess.setAccessible(true);

            String[] cmd = new String[]{"sh", "-c", "input keyevent " + keyCode};
            process = newProcess.invoke(null, new Object[]{cmd, null, null});

            Method waitFor = process.getClass().getMethod("waitFor");
            Object exitObj = waitFor.invoke(process);
            int exitCode = ((Number) exitObj).intValue();

            try {
                Method destroy = process.getClass().getMethod("destroy");
                destroy.invoke(process);
            } catch (Throwable ignored) {}

            if (exitCode == 0) {
                return new Result(true, "Sent Android keyevent " + keyCode);
            }
            return new Result(false, "keyevent " + keyCode + " exited with code " + exitCode);
        } catch (Throwable t) {
            try {
                if (process != null) {
                    Method destroy = process.getClass().getMethod("destroy");
                    destroy.invoke(process);
                }
            } catch (Throwable ignored) {}

            Throwable cause = t.getCause() != null ? t.getCause() : t;
            String msg = cause.getMessage();
            if (msg == null || msg.trim().isEmpty()) msg = cause.getClass().getSimpleName();
            return new Result(false, "Shizuku command failed: " + msg);
        }
    }

    public static final class Result {
        public final boolean success;
        public final String message;

        public Result(boolean success, String message) {
            this.success = success;
            this.message = message;
        }
    }
}
