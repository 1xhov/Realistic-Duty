// postal.js
// Deterministic postal calculation based on world coordinates.
// This runs in the NUI (browser) and sends the result back to the client Lua
// via a registered NUI callback endpoint.

(function(){
    'use strict';

    function computePostal(coords){
        // coords: { x, y, z }
        // Simple deterministic hash combining x/y to produce a 5-digit postal.
        const x = Math.floor(coords.x || 0);
        const y = Math.floor(coords.y || 0);
        // Use bitwise-ish hashing but keep in range
        const seed = Math.abs((x * 73856093) ^ (y * 19349663));
        const postalNum = 10000 + (seed % 89999);
        return String(postalNum);
    }

    // Listen for computePostal requests from Lua
    window.addEventListener('message', function(event){
        const d = event.data;
        if(!d || d.type !== 'computePostal') return;
        const coords = d.coords || { x: 0, y: 0, z: 0 };
        const requestId = d.requestId || null;
        const postal = computePostal(coords);

        try{
            // Post back to the resource's NUI callback. Replace the resource name
            // below with your resource folder name if different. This will trigger
            // RegisterNUICallback('postalResult', ...) in the client Lua.
            fetch('https://Patrol-vision-body-cam/postalResult', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json; charset=utf-8' },
                body: JSON.stringify({ requestId: requestId, postal: postal })
            }).catch(function(e){
                console.error('postal.js: failed to post postalResult', e);
            });
        }catch(e){
            console.error('postal.js: unexpected error', e);
        }
    });

})();
