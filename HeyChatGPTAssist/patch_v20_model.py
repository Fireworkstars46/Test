from pathlib import Path
Path('app/src/main/java/com/example/heychatgptassist/LocalModelManager.java').write_text(r'''package com.example.heychatgptassist;

import android.content.Context;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.Locale;

public final class LocalModelManager {
    private LocalModelManager() {}

    public static final String MODEL_NAME = "Qwen2.5-0.5B-Instruct-Q4_0-v20.gguf";
    private static final String LEGACY_MODEL_NAME = "qwen2.5-0.5b-instruct-q4_0.gguf";
    public static final long MIN_READY_BYTES = 330L * 1024L * 1024L;
    private static final String MODEL_URL = "https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/a9e606ce42ee093b20b8d3b3132a827242c03c39/Qwen2.5-0.5B-Instruct-Q4_0.gguf?download=true";
    private static final String EXPECTED_SHA256 = "2870b7ccba920d5bdd7625c05feef9ccd2d4d2e96352808dc78d434509a5ee8c";

    public interface Callback {
        void onProgress(int percent);
        void onComplete(File file);
        void onError(String message);
    }

    private static File modelDir(Context context) {
        return new File(context.getFilesDir(), "local_models");
    }

    public static File getModelFile(Context context) {
        return new File(modelDir(context), MODEL_NAME);
    }

    private static File getLegacyModelFile(Context context) {
        return new File(modelDir(context), LEGACY_MODEL_NAME);
    }

    public static boolean isModelReady(Context context) {
        File f = getModelFile(context);
        return f.isFile() && f.length() >= MIN_READY_BYTES;
    }

    public static boolean hasLegacyV19Model(Context context) {
        return getLegacyModelFile(context).isFile();
    }

    public static boolean deleteModel(Context context) {
        File f = getModelFile(context);
        File part = new File(modelDir(context), MODEL_NAME + ".part");
        File legacy = getLegacyModelFile(context);
        File legacyPart = new File(modelDir(context), LEGACY_MODEL_NAME + ".part");
        boolean existed = f.exists() || part.exists() || legacy.exists() || legacyPart.exists();
        if (f.exists()) f.delete();
        if (part.exists()) part.delete();
        if (legacy.exists()) legacy.delete();
        if (legacyPart.exists()) legacyPart.delete();
        return existed;
    }

    public static void download(Context context, Callback callback) {
        final Context app = context.getApplicationContext();
        new Thread(() -> {
            HttpURLConnection c = null;
            FileOutputStream out = null;
            try {
                File target = getModelFile(app);
                File dir = target.getParentFile();
                if (!dir.exists() && !dir.mkdirs()) throw new Exception("could not create model folder");
                if (dir.getUsableSpace() < 430L * 1024L * 1024L) {
                    throw new Exception("need about 430 MB free storage");
                }
                File part = new File(dir, MODEL_NAME + ".part");
                if (part.exists()) part.delete();

                URL url = new URL(MODEL_URL);
                c = (HttpURLConnection) url.openConnection();
                c.setConnectTimeout(20000);
                c.setReadTimeout(30000);
                c.setInstanceFollowRedirects(true);
                c.setRequestProperty("User-Agent", "HeyChatGPTAssist/2.0");
                c.connect();
                int code = c.getResponseCode();
                if (code < 200 || code >= 300) throw new Exception("HTTP " + code);
                long total = c.getContentLengthLong();

                MessageDigest digest = MessageDigest.getInstance("SHA-256");
                BufferedInputStream in = new BufferedInputStream(c.getInputStream(), 64 * 1024);
                out = new FileOutputStream(part);
                byte[] buffer = new byte[64 * 1024];
                long done = 0L;
                int lastPercent = -1;
                int n;
                while ((n = in.read(buffer)) >= 0) {
                    if (n == 0) continue;
                    out.write(buffer, 0, n);
                    digest.update(buffer, 0, n);
                    done += n;
                    if (total > 0L) {
                        int p = (int) Math.min(100L, done * 100L / total);
                        if (p != lastPercent) {
                            lastPercent = p;
                            callback.onProgress(p);
                        }
                    }
                }
                in.close();
                out.flush();
                out.close(); out = null;

                StringBuilder hex = new StringBuilder();
                for (byte b : digest.digest()) hex.append(String.format(Locale.US, "%02x", b & 0xff));
                if (!EXPECTED_SHA256.equalsIgnoreCase(hex.toString())) {
                    part.delete();
                    throw new Exception("download checksum did not match");
                }
                if (target.exists()) target.delete();
                if (!part.renameTo(target)) throw new Exception("could not finish model file");

                // The v1.9 model is not needed after the corrected model is ready.
                File legacy = getLegacyModelFile(app);
                if (legacy.exists()) legacy.delete();
                callback.onProgress(100);
                callback.onComplete(target);
            } catch (Throwable t) {
                callback.onError(t.getMessage() == null ? t.getClass().getSimpleName() : t.getMessage());
            } finally {
                try { if (out != null) out.close(); } catch (Throwable ignored) {}
                if (c != null) c.disconnect();
            }
        }, "local-model-download").start();
    }
}
''')
