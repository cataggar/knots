const env = {
	memory: new WebAssembly.Memory({ initial: 512, maximum: 8192 }),
	__stack_pointer: 0,
};

var zjb = new Zjb();

(function () {
	WebAssembly.instantiateStreaming(fetch("playground.wasm"), { env: env, zjb: zjb.imports }).then(function (results) {
		zjb.setInstance(results.instance);
		results.instance.exports.main();
	}).catch(function (err) {
		console.error("failed to instantiate playground.wasm", err);
	});
})();
