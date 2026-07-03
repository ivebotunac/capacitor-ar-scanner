package com.scalesforgrams.plugins.arscanner;

import android.annotation.SuppressLint;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Matrix;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraManager;
import android.util.Base64;
import android.view.ViewGroup;
import android.webkit.WebView;
import androidx.annotation.NonNull;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.ImageCapture;
import androidx.camera.core.ImageCaptureException;
import androidx.camera.core.ImageProxy;
import androidx.camera.core.Preview;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.view.PreviewView;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.LifecycleOwner;
import com.getcapacitor.JSObject;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Manages a CameraX preview behind a transparent WebView on Android.
 * Captures photos for Gemini AI analysis (no depth/AR measurement).
 */
public class CameraPreviewManager {

    public interface CaptureCallback {
        void onResult(JSObject result);
        void onError(String message);
    }

    public interface StartCallback {
        void onStarted();
        void onError(String message);
    }

    private ProcessCameraProvider cameraProvider;
    private Camera camera;
    private ImageCapture imageCapture;
    private PreviewView previewView;
    private ExecutorService cameraExecutor;
    private boolean isRunning = false;

    public boolean isRunning() {
        return isRunning;
    }

    @SuppressLint("SetJavaScriptEnabled")
    public void start(WebView webView, LifecycleOwner lifecycleOwner, StartCallback callback) {
        if (isRunning) {
            if (callback != null) callback.onStarted();
            return;
        }

        Context context = webView.getContext();
        cameraExecutor = Executors.newSingleThreadExecutor();

        // Create PreviewView and insert below WebView
        previewView = new PreviewView(context);
        previewView.setLayoutParams(new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        ViewGroup parent = (ViewGroup) webView.getParent();
        if (parent != null) {
            // Insert at index 0 (very bottom of z-order). The EdgeToEdge plugin
            // adds two coloured overlays for the status & navigation bar zones
            // earlier in the children list — we keep PreviewView underneath
            // those overlays so they paint over the camera in the bar zones.
            // Otherwise the MATCH_PARENT preview bleeds edge-to-edge.
            parent.addView(previewView, 0);
        }

        // Make WebView transparent
        webView.setBackgroundColor(Color.TRANSPARENT);

        // Start CameraX. Completion is reported through the callback so the JS bridge only
        // resolves startPreview once the camera is actually bound — resolving early opened a
        // 1-3s window on slow devices where capture() failed with "Preview is not running".
        var cameraProviderFuture = ProcessCameraProvider.getInstance(context);
        cameraProviderFuture.addListener(() -> {
            try {
                cameraProvider = cameraProviderFuture.get();

                Preview preview = new Preview.Builder().build();
                preview.setSurfaceProvider(previewView.getSurfaceProvider());

                imageCapture = new ImageCapture.Builder()
                    .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
                    .setTargetRotation(webView.getDisplay().getRotation())
                    .build();

                CameraSelector cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA;

                cameraProvider.unbindAll();
                camera = cameraProvider.bindToLifecycle(lifecycleOwner, cameraSelector, preview, imageCapture);

                isRunning = true;
                if (callback != null) callback.onStarted();
            } catch (Exception e) {
                e.printStackTrace();
                cleanupViews(webView);
                if (callback != null) {
                    callback.onError(e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName());
                }
            }
        }, ContextCompat.getMainExecutor(context));
    }

    /** Remove the PreviewView and restore the WebView background after a failed bind. */
    private void cleanupViews(WebView webView) {
        if (previewView != null) {
            ViewGroup parent = (ViewGroup) previewView.getParent();
            if (parent != null) {
                parent.removeView(previewView);
            }
            previewView = null;
        }
        if (webView != null) {
            webView.setBackgroundColor(Color.BLACK);
        }
    }

    public void stop(WebView webView) {
        if (!isRunning) return;
        isRunning = false;

        if (cameraProvider != null) {
            cameraProvider.unbindAll();
            cameraProvider = null;
        }

        // Removes PreviewView and restores WebView background to black (avoid white flash)
        cleanupViews(webView);

        camera = null;
        imageCapture = null;

        if (cameraExecutor != null) {
            cameraExecutor.shutdown();
            cameraExecutor = null;
        }
    }

    public boolean setTorch(boolean enabled) {
        if (camera == null) return false;
        if (!camera.getCameraInfo().hasFlashUnit()) return false;
        camera.getCameraControl().enableTorch(enabled);
        return enabled;
    }

    public void capture(CaptureCallback callback) {
        if (!isRunning || imageCapture == null) {
            callback.onError("Camera not running");
            return;
        }

        imageCapture.takePicture(
            cameraExecutor,
            new ImageCapture.OnImageCapturedCallback() {
                @Override
                public void onCaptureSuccess(@NonNull ImageProxy imageProxy) {
                    try {
                        Bitmap bitmap = imageProxyToBitmap(imageProxy);
                        imageProxy.close();

                        if (bitmap == null) {
                            callback.onError("Failed to convert image");
                            return;
                        }

                        // High-res capped at 1280px: the analysis backend downscales to 1280
                        // anyway (Gemini tiling cost), so uploading more only slows down and
                        // destabilizes the request on poor networks.
                        String highRes = resizeThenEncode(bitmap, 1280, 80);
                        String thumbnail = resizeThenEncode(bitmap, 1024, 80);
                        bitmap.recycle();

                        JSObject result = new JSObject();
                        result.put("hasLidar", false);
                        result.put("width", 0);
                        result.put("height", 0);
                        result.put("depth", 0);
                        result.put("volume", 0);
                        result.put("depthQuality", "estimated");
                        result.put("pointCount", 0);
                        result.put("measureMethod", "lidar");
                        if (highRes != null) result.put("capturedImageBase64", highRes);
                        if (thumbnail != null) result.put("thumbnailBase64", thumbnail);

                        callback.onResult(result);
                    } catch (Exception e) {
                        callback.onError("Capture processing failed: " + e.getMessage());
                    }
                }

                @Override
                public void onError(@NonNull ImageCaptureException exception) {
                    callback.onError("Capture failed: " + exception.getMessage());
                }
            }
        );
    }

    // ── Image helpers ──

    private Bitmap imageProxyToBitmap(ImageProxy imageProxy) {
        ImageProxy.PlaneProxy[] planes = imageProxy.getPlanes();
        if (planes.length == 0) return null;

        ByteBuffer buffer = planes[0].getBuffer();
        byte[] bytes = new byte[buffer.remaining()];
        buffer.get(bytes);

        Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        if (bitmap == null) return null;

        // Apply rotation from EXIF
        int rotation = imageProxy.getImageInfo().getRotationDegrees();
        if (rotation != 0) {
            Matrix matrix = new Matrix();
            matrix.postRotate(rotation);
            Bitmap rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), matrix, true);
            bitmap.recycle();
            return rotated;
        }

        return bitmap;
    }

    private String resizeThenEncode(Bitmap source, int maxDimension, int quality) {
        float scale = Math.min((float) maxDimension / source.getWidth(), (float) maxDimension / source.getHeight());
        scale = Math.min(scale, 1.0f);

        int newWidth = Math.round(source.getWidth() * scale);
        int newHeight = Math.round(source.getHeight() * scale);
        Bitmap resized = Bitmap.createScaledBitmap(source, newWidth, newHeight, true);

        ByteArrayOutputStream stream = new ByteArrayOutputStream();
        resized.compress(Bitmap.CompressFormat.JPEG, quality, stream);
        if (resized != source) resized.recycle();

        return Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP);
    }
}
