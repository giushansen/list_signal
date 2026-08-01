// Flashes clear themselves. 4s rather than 2s: an error message the user
// cannot finish reading is the same as no message at all, and errors here
// carry real instructions ("narrow your filter", "slow down").
const AutoClearFlashHook = {
    mounted() {
        this.timer = setTimeout(() => {
            this.el.style.transition = "opacity 300ms";
            this.el.style.opacity = "0";
            setTimeout(() => this.el.remove(), 300);
        }, 4000);
    },
    destroyed() {
        clearTimeout(this.timer);
    }
};

export default AutoClearFlashHook;
