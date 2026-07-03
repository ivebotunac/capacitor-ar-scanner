package com.scalesforgrams.plugins.arscanner;

import android.Manifest;
import android.os.Handler;
import android.os.Looper;
import android.webkit.WebView;
import androidx.lifecycle.LifecycleOwner;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

@CapacitorPlugin(name = "ARScanner", permissions = { @Permission(strings = { Manifest.permission.CAMERA }, alias = "camera") })
public class ARScannerPlugin extends Plugin {

    private static final String CAMERA_ALIAS = "camera";

    private CameraPreviewManager previewManager;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    @PluginMethod
    public void checkSupport(PluginCall call) {
        JSObject result = new JSObject();
        result.put("isSupported", true);
        result.put("hasLidar", false);
        result.put("hasDepthApi", false);
        result.put("depthQuality", "estimated");
        call.resolve(result);
    }

    @PluginMethod
    public void startPreview(PluginCall call) {
        if (getPermissionState(CAMERA_ALIAS) != PermissionState.GRANTED) {
            requestPermissionForAlias(CAMERA_ALIAS, call, "cameraPermissionCallback");
            return;
        }
        doStartPreview(call);
    }

    @PermissionCallback
    private void cameraPermissionCallback(PluginCall call) {
        if (getPermissionState(CAMERA_ALIAS) == PermissionState.GRANTED) {
            doStartPreview(call);
        } else {
            call.reject("Camera permission denied");
        }
    }

    private void doStartPreview(PluginCall call) {
        mainHandler.post(() -> {
            try {
                WebView webView = getBridge().getWebView();
                LifecycleOwner lifecycleOwner = (LifecycleOwner) getActivity();

                if (previewManager != null) {
                    previewManager.stop(webView);
                }

                previewManager = new CameraPreviewManager();
                // Resolve only when CameraX is actually bound: resolving early made the JS
                // side mark the preview as running 1-3s before it really was, and every
                // capture() in that window failed with "Preview is not running".
                previewManager.start(webView, lifecycleOwner, new CameraPreviewManager.StartCallback() {
                    @Override
                    public void onStarted() {
                        JSObject result = new JSObject();
                        result.put("started", true);
                        call.resolve(result);
                    }

                    @Override
                    public void onError(String message) {
                        notifyScanError("Failed to start camera: " + message);
                        call.reject("Failed to start camera: " + message);
                    }
                });
            } catch (Exception e) {
                call.reject("Failed to start preview: " + e.getMessage());
            }
        });
    }

    /**
     * Mirror of the iOS scanEvent error contract so the web layer's capture issue
     * tracking works on Android too (previously Android emitted no scanEvents at all).
     */
    private void notifyScanError(String message) {
        JSObject event = new JSObject();
        event.put("type", "error");
        event.put("message", message);
        notifyListeners("scanEvent", event);
    }

    @PluginMethod
    public void stopPreview(PluginCall call) {
        mainHandler.post(() -> {
            if (previewManager != null) {
                WebView webView = getBridge().getWebView();
                previewManager.stop(webView);
                previewManager = null;
            }
            JSObject result = new JSObject();
            result.put("stopped", true);
            call.resolve(result);
        });
    }

    @PluginMethod
    public void capture(PluginCall call) {
        if (previewManager == null || !previewManager.isRunning()) {
            call.reject("Preview is not running. Call startPreview() first.");
            return;
        }

        previewManager.capture(
            new CameraPreviewManager.CaptureCallback() {
                @Override
                public void onResult(JSObject result) {
                    call.resolve(result);
                }

                @Override
                public void onError(String message) {
                    notifyScanError(message);
                    call.reject(message);
                }
            }
        );
    }

    @PluginMethod
    public void setTorch(PluginCall call) {
        boolean enabled = call.getBoolean("enabled", false);

        if (previewManager == null || !previewManager.isRunning()) {
            call.reject("Preview is not running");
            return;
        }

        mainHandler.post(() -> {
            boolean result = previewManager.setTorch(enabled);
            JSObject res = new JSObject();
            res.put("enabled", result);
            call.resolve(res);
        });
    }
}
