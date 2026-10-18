package org.lineageos.desktop.mode;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.pm.PackageManager;
import android.content.res.TypedArray;
import android.graphics.drawable.Drawable;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Desktop/TV: the desktop's launcher (Trebuchet) under a Desktop mode heading, then each TV
 * launcher, Catapult first, under a TV mode heading. In TV mode, a TV launcher becomes the Home
 * app at once, and the desktop's launcher asks to restart in the desktop. On the desktop, a TV
 * launcher asks to restart in TV mode, with it as the Home app.
 */
public class SwitcherActivity extends Activity {
    private static final int DESKTOP_HEADING = 0;
    private static final int DESKTOP = 1;
    private static final int TV_HEADING = 2;

    // How long the list shows a new choice before the restart question covers it.
    private static final long ASK_DELAY_MS = 300;

    // Set from a choice that needs a restart until the question about it is answered: the list
    // takes no other choice meanwhile.
    private boolean mAsking;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        boolean tv = ModeController.isTvMode();
        PackageManager pm = getPackageManager();
        List<String> launchers = tvLaunchers(pm);
        List<CharSequence> labels = new ArrayList<>();
        labels.add(getString(R.string.desktop_mode_heading));
        labels.add(label(pm, ModeController.DESKTOP_LAUNCHER));
        labels.add(getString(R.string.tv_mode_heading));
        for (String packageName : launchers) {
            labels.add(label(pm, packageName));
        }
        final int checked;
        if (tv) {
            List<String> holders = ModeController.homeHolders(this);
            int home = holders.isEmpty() ? -1 : launchers.indexOf(holders.get(0));
            checked = home < 0 ? -1 : TV_HEADING + 1 + home;
        } else {
            checked = DESKTOP;
        }
        new AlertDialog.Builder(this)
                .setTitle(R.string.switcher_title)
                .setIcon(R.drawable.ic_ika)
                .setSingleChoiceItems(new RowAdapter(this, labels), checked, (dialog, which) -> {
                    if (mAsking) {
                        return;
                    }
                    if (which == DESKTOP) {
                        if (tv) {
                            ask((AlertDialog) dialog, checked, false, null);
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
                        ask((AlertDialog) dialog, checked, true, launcher);
                    }
                })
                .setNegativeButton(android.R.string.cancel, null)
                .setOnDismissListener(dialog -> finish())
                .show();
    }

    /**
     * Asks, over the list, which shows the new choice, to restart in the other mode with HOME as
     * its Home app. Otherwise it goes back to the list, with the current choice, CHECKED, again.
     */
    private void ask(AlertDialog list, int checked, boolean tv, String home) {
        mAsking = true;
        list.getListView().postDelayed(() -> showQuestion(list, checked, tv, home),
                ASK_DELAY_MS);
    }

    private void showQuestion(AlertDialog list, int checked, boolean tv, String home) {
        if (isFinishing()) {
            return;
        }
        boolean[] switching = {false};
        new AlertDialog.Builder(this)
                .setTitle(tv ? R.string.tv_mode_title : R.string.desktop_mode_title)
                .setMessage(tv ? R.string.tv_mode_text : R.string.desktop_mode_text)
                .setPositiveButton(R.string.switch_mode, (dialog, which) -> {
                    switching[0] = true;
                    list.dismiss();
                    ModeController.EXECUTOR.execute(() -> ModeController.switchTo(
                            getApplicationContext(), tv, home));
                })
                .setNegativeButton(android.R.string.cancel, null)
                .setOnDismissListener(dialog -> {
                    if (switching[0]) {
                        return;
                    }
                    mAsking = false;
                    ListView rows = list.getListView();
                    if (checked < 0) {
                        rows.clearChoices();
                        rows.requestLayout();
                    } else {
                        rows.setItemChecked(checked, true);
                    }
                })
                .show();
    }

    /** The TV launchers, Catapult first, then by name. */
    private static List<String> tvLaunchers(PackageManager pm) {
        List<String> launchers = ModeController.tvLaunchers(pm);
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

    private static CharSequence label(PackageManager pm, String packageName) {
        try {
            return pm.getApplicationInfo(packageName, PackageManager.MATCH_DISABLED_COMPONENTS)
                    .loadLabel(pm);
        } catch (PackageManager.NameNotFoundException e) {
            return packageName;
        }
    }

    /** The choices as the dialog's own single-choice rows, under a heading for each mode. */
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
            return position != DESKTOP_HEADING && position != TV_HEADING;
        }

        @Override
        public int getViewTypeCount() {
            return 3;
        }

        @Override
        public int getItemViewType(int position) {
            return position == DESKTOP_HEADING ? 1 : position == TV_HEADING ? 2 : 0;
        }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            if (position == DESKTOP_HEADING || position == TV_HEADING) {
                return convertView != null ? convertView : heading(position);
            }
            TextView row = (TextView) (convertView != null ? convertView
                    : LayoutInflater.from(mContext).inflate(
                            com.android.internal.R.layout.select_dialog_singlechoice_material,
                            parent, false));
            row.setText(mLabels.get(position));
            return row;
        }

        /**
         * The heading in the accent colour, lined up with the rows' text: below the title for
         * desktop mode, below a line for TV mode.
         */
        private View heading(int position) {
            float density = mContext.getResources().getDisplayMetrics().density;
            LinearLayout heading = new LinearLayout(mContext);
            heading.setOrientation(LinearLayout.VERTICAL);
            if (position == TV_HEADING) {
                View line = new View(mContext);
                line.setBackground(themeDrawable(android.R.attr.listDivider));
                LinearLayout.LayoutParams lineParams = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, Math.max(1, Math.round(density)));
                lineParams.topMargin = Math.round(8 * density);
                heading.addView(line, lineParams);
            }
            TextView title = new TextView(mContext);
            title.setTextAppearance(android.R.style.TextAppearance_Material_Body2);
            title.setTextColor(themeColor(android.R.attr.colorAccent));
            title.setText(mLabels.get(position));
            int padding = themeSize(android.R.attr.dialogPreferredPadding,
                    Math.round(24 * density));
            title.setPaddingRelative(padding,
                    Math.round((position == DESKTOP_HEADING ? 20 : 16) * density), padding,
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
