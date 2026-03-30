const plugin = require("tailwindcss/plugin")

module.exports = {
  content: ["./js/**/*.js", "../lib/ls_web/**/*.*ex"],
  theme: {
    extend: {
      colors: {
        "ls-dark": "#080E1E",
        "ls-dark-2": "#0C1429",
        "ls-dark-3": "#111B33",
        accent: {
          DEFAULT: "#10B981",
          hover: "#34D399",
        },
      },
      fontFamily: {
        display: ["Sora", "system-ui", "sans-serif"],
        body: ["DM Sans", "system-ui", "sans-serif"],
      },
      animation: {
        ticker: "ticker 60s linear infinite",
        "fade-in-up": "fadeInUp 0.6s ease-out",
        "fade-in-up-delay": "fadeInUp 0.6s ease-out 0.08s backwards",
        "fade-in-up-delay-2": "fadeInUp 0.6s ease-out 0.16s backwards",
        "fade-in-up-delay-3": "fadeInUp 0.6s ease-out 0.24s backwards",
        "fade-in-down": "fadeInDown 0.5s ease-out",
      },
      keyframes: {
        ticker: {
          "0%": { transform: "translateX(0)" },
          "100%": { transform: "translateX(-50%)" },
        },
        fadeInUp: {
          from: { opacity: "0", transform: "translateY(20px)" },
          to: { opacity: "1", transform: "translateY(0)" },
        },
        fadeInDown: {
          from: { opacity: "0", transform: "translateY(-14px)" },
          to: { opacity: "1", transform: "translateY(0)" },
        },
      },
    },
  },
  plugins: [
    plugin(function ({ addUtilities }) {
      addUtilities({
        ".anim": {
          opacity: "0",
          transform: "translateY(24px)",
          transition: "opacity 0.5s ease-out, transform 0.5s ease-out",
        },
        ".anim.visible": {
          opacity: "1",
          transform: "translateY(0)",
        },
      })
    }),
  ],
}
