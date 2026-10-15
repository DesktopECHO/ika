package org.lineageos.desktop.mode;

import android.app.Application;

/** Applies Ika's mode as Android starts: this app is persistent. */
public class IkaModeApplication extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        ModeController.EXECUTOR.execute(() -> ModeController.apply(this));
    }
}
