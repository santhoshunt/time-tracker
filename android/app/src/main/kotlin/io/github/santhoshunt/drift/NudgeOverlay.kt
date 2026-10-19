package io.github.santhoshunt.drift

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.ClipDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.graphics.drawable.RippleDrawable
import android.hardware.display.DisplayManager
import android.os.Build
import android.util.TypedValue
import android.view.Display
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * The full-screen nudge (option B in plans/decisions.md), drawn over the
 * app the user drifted into.
 *
 * An app cannot close another app, so the two ways out are "Go to home
 * screen", which launches the HOME intent, and "5 more minutes", which
 * snoozes that package. The back key only dismisses. Views are built in
 * code so the overlay needs no layout resources that R8 could strip.
 *
 * Main thread only. At most one overlay exists at a time; a new nudge
 * replaces the old one.
 */
object NudgeOverlay {
    /** 45% black over the app underneath. */
    private const val SCRIM = 0x73000000
    private const val MAX_CARD_DP = 420

    /** How long "Hold to open anyway" must be held. */
    private const val HOLD_MS = 3_000L

    private var view: View? = null
    private var windowManager: WindowManager? = null

    /** The package the visible overlay is about, or null. Read by the
     * service's tick thread to dismiss it once the user moves on. */
    @Volatile
    var showingFor: String? = null
        private set

    fun show(
        context: Context,
        pkg: String,
        label: String,
        nudge: NudgeDecision.Nudge,
        colors: NudgeColors,
        onSnooze: (String) -> Unit,
    ) {
        dismiss()
        val ui = windowContext(context)
        val wm = ui.getSystemService(WindowManager::class.java) ?: return

        val root = object : FrameLayout(ui) {
            override fun dispatchKeyEvent(event: KeyEvent): Boolean {
                if (event.keyCode == KeyEvent.KEYCODE_BACK) {
                    // A lock that back could close would not lock anything,
                    // so back leaves for the home screen instead.
                    if (event.action == KeyEvent.ACTION_UP) {
                        if (nudge.lock) goHome(ui)
                        dismiss()
                    }
                    return true
                }
                return super.dispatchKeyEvent(event)
            }
        }
        root.setBackgroundColor(SCRIM)
        // Taps on the scrim do nothing; only the buttons or back leave.
        root.isClickable = true
        root.isFocusable = true
        root.isFocusableInTouchMode = true

        val card = LinearLayout(ui).apply {
            orientation = LinearLayout.VERTICAL
            val pad = dp(ui, 24)
            setPadding(pad, pad, pad, pad)
            background = GradientDrawable().apply {
                cornerRadius = dp(ui, 20).toFloat()
                setColor(colors.card)
            }
            isClickable = true
        }
        card.addView(
            TextView(ui).apply {
                text = if (nudge.lock) "${nudge.block} is locked" else "You planned ${nudge.block}"
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
                setTextColor(colors.text)
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                isAccessibilityHeading = true
            }
        )
        card.addView(
            TextView(ui).apply {
                text = body(label, nudge)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                setTextColor(colors.text)
                setLineSpacing(0f, 1.2f)
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(ui, 12) }
        )
        card.addView(
            button(ui, "Go to home screen", fill = colors.accent, stroke = null, textColor = colors.onAccent) {
                goHome(ui)
                dismiss()
            },
            buttonParams(ui, top = 24)
        )
        card.addView(
            if (nudge.lock) {
                holdButton(ui, "Hold to open anyway", colors) {
                    onSnooze(pkg)
                    dismiss()
                }
            } else {
                button(ui, "5 more minutes", fill = colors.card, stroke = colors.accent, textColor = colors.text) {
                    onSnooze(pkg)
                    dismiss()
                }
            },
            buttonParams(ui, top = 12)
        )

        // Large font scales can make the card taller than the screen, so it
        // scrolls; fillViewport keeps it centred when it fits.
        val scroll = ScrollView(ui).apply { isFillViewport = true }
        val centre = FrameLayout(ui)
        val margin = dp(ui, 24)
        val width = minOf(
            ui.resources.displayMetrics.widthPixels - 2 * margin,
            dp(ui, MAX_CARD_DP)
        )
        centre.addView(
            card,
            FrameLayout.LayoutParams(width, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER)
                .apply { setMargins(0, margin, 0, margin) }
        )
        scroll.addView(
            centre,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )
        root.addView(
            scroll,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )

        // Focusable (no FLAG_NOT_FOCUSABLE) so the back key reaches it.
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply { title = "Drift nudge" }
        wm.addView(root, params)
        root.requestFocus()
        view = root
        windowManager = wm
        showingFor = pkg
    }

    fun dismiss() {
        val v = view ?: return
        try {
            windowManager?.removeView(v)
        } catch (_: Exception) {
            // Already removed, for example with the service.
        }
        view = null
        windowManager = null
        showingFor = null
    }

    fun body(label: String, nudge: NudgeDecision.Nudge): String =
        if (nudge.lock) {
            "$label is off track here. ${nudge.minutesLeft} min left in this block."
        } else {
            "$label for ${nudge.minutesOff} min. ${nudge.minutesLeft} min left in this block."
        }

    /**
     * The lock card's way through: holding fills the button left to right
     * over [HOLD_MS]; letting go early empties it again, and a full hold
     * calls [onDone]. A deliberate hold rather than a tap, so opening a
     * locked app is a choice and not a reflex.
     */
    private fun holdButton(
        context: Context,
        label: String,
        colors: NudgeColors,
        onDone: () -> Unit,
    ): TextView {
        val radius = dp(context, 24).toFloat()
        val track = GradientDrawable().apply {
            cornerRadius = radius
            setColor(colors.card)
            setStroke(dp(context, 1), colors.accent)
        }
        // The fill is the accent at low alpha, so the label in the text
        // colour stays readable over it.
        val fill = ClipDrawable(
            GradientDrawable().apply {
                cornerRadius = radius
                setColor((colors.accent and 0x00FFFFFF) or 0x55000000)
            },
            Gravity.START,
            ClipDrawable.HORIZONTAL
        )
        val view = TextView(context).apply {
            text = label
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTextColor(colors.text)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            gravity = Gravity.CENTER
            minHeight = dp(context, 48)
            val h = dp(context, 20)
            val v = dp(context, 12)
            setPadding(h, v, h, v)
            background = LayerDrawable(arrayOf(track, fill))
            isClickable = true
            isFocusable = true
            contentDescription = "$label. Hold for 3 seconds."
        }
        var done = false
        val animator = ValueAnimator.ofInt(0, 10_000).apply {
            duration = HOLD_MS
            addUpdateListener { fill.level = it.animatedValue as Int }
            addListener(object : AnimatorListenerAdapter() {
                private var cancelled = false

                override fun onAnimationStart(animation: Animator) {
                    cancelled = false
                }

                override fun onAnimationCancel(animation: Animator) {
                    cancelled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                    if (cancelled || done) return
                    done = true
                    onDone()
                }
            })
        }
        view.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    v.isPressed = true
                    animator.start()
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    v.isPressed = false
                    if (!done) {
                        animator.cancel()
                        fill.level = 0
                    }
                    if (event.actionMasked == MotionEvent.ACTION_UP) v.performClick()
                }
            }
            true
        }
        // A tap does nothing on its own; performClick is called for
        // accessibility services, which report the click.
        view.setOnClickListener { }
        return view
    }

    /** Android 11+ warns when a non-visual context such as a service adds
     * windows; a window context carries the right display and density. */
    private fun windowContext(context: Context): Context {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return context
        val display = context.getSystemService(DisplayManager::class.java)
            ?.getDisplay(Display.DEFAULT_DISPLAY) ?: return context
        return context.createWindowContext(
            display,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            null
        )
    }

    /** Started while the overlay is still visible: a visible overlay window
     * is what lets a background app start an activity on Android 15. */
    private fun goHome(context: Context) {
        try {
            context.startActivity(NudgeService.homeIntent())
        } catch (_: Exception) {
            // No launcher answered; dismissing still frees the screen.
        }
    }

    private fun button(
        context: Context,
        label: String,
        fill: Int,
        stroke: Int?,
        textColor: Int,
        onClick: () -> Unit,
    ): TextView {
        val radius = dp(context, 24).toFloat()
        val shape = GradientDrawable().apply {
            cornerRadius = radius
            setColor(fill)
            if (stroke != null) setStroke(dp(context, 1), stroke)
        }
        val mask = GradientDrawable().apply {
            cornerRadius = radius
            setColor(0xFFFFFFFF.toInt())
        }
        // The press ripple is the text colour at low alpha, so it shows on
        // either fill.
        val ripple = (textColor and 0x00FFFFFF) or 0x33000000
        return TextView(context).apply {
            text = label
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTextColor(textColor)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            gravity = Gravity.CENTER
            minHeight = dp(context, 48)
            val h = dp(context, 20)
            val v = dp(context, 12)
            setPadding(h, v, h, v)
            background = RippleDrawable(ColorStateList.valueOf(ripple), shape, mask)
            isClickable = true
            isFocusable = true
            setOnClickListener { onClick() }
        }
    }

    private fun buttonParams(context: Context, top: Int) = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT
    ).apply { topMargin = dp(context, top) }

    private fun dp(context: Context, value: Int): Int =
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            context.resources.displayMetrics
        ).toInt()
}
