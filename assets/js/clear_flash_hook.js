const AutoClearFlashHook = {
    mounted() {
        setTimeout(() => {
            this.el.remove();
        }, 2000); // 2 seconds
    }
};

export default AutoClearFlashHook;
