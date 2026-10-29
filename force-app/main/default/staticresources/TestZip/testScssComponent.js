import { LightningElement, track } from 'lwc';

export default class TestScssComponent extends LightningElement {
    @track clickMessage = '';

    handleClick(event) {
        const buttonType = event.target.className.split('--')[1];
        this.clickMessage = `You clicked the ${buttonType} button! If styles are working correctly, this should be styled.`;
    }
}
