package org.lineageos.desktop.mode;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.pm.FeatureInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.content.res.TypedArray;
import android.graphics.drawable.Drawable;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Desktop/TV: Desktop Mode, then a TV mode heading over each TV launcher, Catapult first. In TV
 * mode, a TV launcher becomes the Home app at once, and Desktop Mode asks to restart in the
 * desktop. On the desktop, a TV launcher asks to restart in TV mode, with it as the Home app.
 */
public class SwitcherActivity extends Activity {
    private static final String TV_SETTINGS = "com.android.tv.settings";
    private static final String LEANBACK = "android.software.leanback";
    private static final int DESKTOP = 0;
    private static final int TV_HEADING = 1;

    // Set while the restart question replaces the list, so that closing the list does not
    // finish the activity.
    private boolean mAsking;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        boolean tv = ModeController.isTvMode();
        PackageManager pm = getPackageManager();
        List<String> launchers = tvLaunchers(pm);
        List<CharSequence> labels = new ArrayList<>();
        labels.add(getString(R.string.desktop_mode_item));
        labels.add(getString(R.string.tv_mode_heading));
        for (String packageName : launchers) {
            labels.add(label(pm, packageName));
        }
        int checked = DESKTOP;
        if (tv) {
            List<String> holders = ModeController.homeHolders(this);
            int home = holders.isEmpty() ? -1 : launchers.indexOf(holders.get(0));
            checked = home < 0 ? -1 : TV_HEADING + 1 + home;
        }
        new AlertDialog.Builder(this)
                .setTitle(R.string.switcher_title)
                .setIcon(R.drawable.ic_ika)
                .setSingleChoiceItems(new RowAdapter(this, labels), checked, (dialog, which) -> {
                    if (which == DESKTOP) {
                        if (tv) {
                            ask(dialog, false, null);
                        } else {
                            dialog.dismiss();
                        }
                        return;
                    }
                    String launcher = launchers.get(which - TV_HEADING - 1);
                    if (tv) {
                        ModeController.EXECUTOR.execute(() -> ModeController.setHome(
                                getApplicationContext(), launcher, success -> {}));
                        dialog.dismiss();
                    } else {
                        ask(dialog, true, launcher);
                    }
                })
                .setNegativeButton(android.R.string.cancel, null)
                .setOnDismissListener(dialog -> {
                    if (!mAsking) {
                        finish();
                    }
                })
                .show();
    }

    /** Closes the list and asks to restart in the other mode, with HOME as its Home app. */
    private void ask(DialogInterface list, boolean tv, String home) {
        mAsking = true;
        list.dismiss();
        new AlertDialog.Builder(this)
                .setTitle(tv ? R.string.tv_mode_title : R.string.desktop_mode_title)
                .setMessage(tv ? R.string.tv_mode_text : R.string.desktop_mode_text)
                .setPositiveButton(R.string.switch_mode, (dialog, which) ->
                        ModeController.EXECUTOR.execute(() -> ModeController.switchTo(
                                getApplicationContext(), tv, home)))
                .setNegativeButton(android.R.string.cancel, null)
                .setOnDismissListener(dialog -> finish())
                .show();
    }

    /**
     * The TV launchers: Home apps made for TV, which declare the leanback feature or have a TV
     * launcher entry, Catapult first. TV Settings' Home is only there for when there is no
     * other. Each mode's launcher is off in the other mode, so disabled apps count too.
     */
    private static List<String> tvLaunchers(PackageManager pm) {
        List<String> launchers = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (ResolveInfo info : pm.queryIntentActivities(
                new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME),
                PackageManager.MATCH_DISABLED_COMPONENTS)) {
            String packageName = info.activityInfo.packageName;
            if (TV_SETTINGS.equals(packageName) || !seen.add(packageName)) {
                continue;
            }
            if (ModeController.TV_LAUNCHER.equals(packageName) || isTvApp(pm, packageName)) {
                launchers.add(packageName);
            }
        }
        Collections.sort(launchers, (a, b) -> {
            if (a.equals(b)) {
                return 0;
            }
            if (ModeController.TV_LAUNCHER.equals(a) || ModeController.TV_LAUNCHER.equals(b)) {
                return ModeController.TV_LAUNCHER.equals(a) ? -1 : 1;
            }
            return label(pm, a).toString().compareToIgnoreCase(label(pm, b).toString());
        });
        return launchers;
    }

    private static boolean isTvApp(PackageManager pm, String packageName) {
        try {
            PackageInfo info = pm.getPackageInfo(packageName,
                    PackageManager.GET_CONFIGURATIONS | PackageManager.MATCH_DISABLED_COMPONENTS);
            if (info.reqFeatures != null) {
                for (FeatureInfo feature : info.reqFeatures) {
                    if (LEANBACK.equals(feature.name)) {
                        return true;
                    }
                }
            }
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
        return !pm.queryIntentActivities(new Intent(Intent.ACTION_MAIN)
                        .addCategory(Intent.CATEGORY_LEANBACK_LAUNCHER).setPackage(packageName),
                PackageManager.MATCH_DISABLED_COMPONENTS).isEmpty();
    }

    private static CharSequence label(PackageManager pm, String packageName) {
        try {
            return pm.getApplicationInfo(packageName, PackageManager.MATCH_DISABLED_COMPONENTS)
                    .loadLabel(pm);
        } catch (PackageManager.NameNotFoundException e) {
            return packageName;
        }
    }

    /** The choices as the dialog's own single-choice rows, with the TV mode heading between. */
    private static final class RowAdapter extends BaseAdapter {
        private final Context mContext;
        private final List<CharSequence> mLabels;

        RowAdapter(Context context, List<CharSequence> labels) {
            mContext = context;
            mLabels = labels;
        }

        @Override
        public int getCount() {
            return mLabels.size();
        }

        @Override
        public Object getItem(int position) {
            return mLabels.get(position);
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public boolean areAllItemsEnabled() {
            return false;
        }

        @Override
        public boolean isEnabled(int position) {
            return position != TV_HEADING;
        }

        @Override
        public int getViewTypeCount() {
            return 2;
        }

        @Override
        public int getItemViewType(int position) {
            return position == TV_HEADING ? 1 : 0;
        }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            if (position == TV_HEADING) {
                return convertView != null ? convertView : heading();
            }
            TextView row = (TextView) (convertView != null ? convertView
                    : LayoutInflater.from(mContext).inflate(
                            com.android.internal.R.layout.select_dialog_singlechoice_material,
                            parent, false));
            row.setText(mLabels.get(position));
            return row;
        }

        /** A line, then the heading in the accent colour, lined up with the rows' text. */
        private View heading() {
            float density = mContext.getResources().getDisplayMetrics().density;
            LinearLayout heading = new LinearLayout(mContext);
            heading.setOrientation(LinearLayout.VERTICAL);
            View line = new View(mContext);
            line.setBackground(themeDrawable(android.R.attr.listDivider));
            LinearLayout.LayoutParams lineParams = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, Math.max(1, Math.round(density)));
            lineParams.topMargin = Math.round(8 * density);
            heading.addView(line, lineParams);
            TextView title = new TextView(mContext);
            title.setTextAppearance(android.R.style.TextAppearance_Material_Body2);
            title.setTextColor(themeColor(android.R.attr.colorAccent));
            title.setText(mLabels.get(TV_HEADING));
            int padding = themeSize(android.R.attr.dialogPreferredPadding,
                    Math.round(24 * density));
            title.setPaddingRelative(padding, Math.round(16 * density), padding,
                    Math.round(10 * density));
            heading.addView(title);
            return heading;
        }

        private Drawable themeDrawable(int attr) {
            TypedArray a = mContext.obtainStyledAttributes(new int[] {attr});
            try {
                return a.getDrawable(0);
            } finally {
                a.recycle();
            }
        }

        private int themeColor(int attr) {
            TypedArray a = mContext.obtainStyledAttributes(new int[] {attr});
            try {
                return a.getColor(0, 0);
            } finally {
                a.recycle();
            }
        }

        private int themeSize(int attr, int fallback) {
            TypedArray a = mContext.obtainStyledAttributes(new int[] {attr});
            try {
                return a.getDimensionPixelSize(0, fallback);
            } finally {
                a.recycle();
            }
        }
    }
}
